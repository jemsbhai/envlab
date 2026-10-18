"""Event-time spatial matching and current server-owned device authorization."""
from bisect import bisect_right, insort
from collections import defaultdict
from copy import deepcopy
import hashlib
from heapq import heappop, heappush
import json
import math
import os
from pathlib import Path
import uuid

from .contract import iso, now_ts
from .dewin_bus import encode


def registry():
    data = json.loads(Path(os.getenv("REGISTRY_PATH", "/run/dewin/devices.json")).read_text())
    return data["devices"]


def can_read(device, user, devices):
    entry = devices.get(device)
    return bool(entry and (entry.get("visibility") == "public" or
                          (entry.get("visibility") == "private" and entry.get("ownerUserId") == user)))


def authorized_result(value, user, devices):
    result = deepcopy(value)
    result["sensors"] = [s for s in result["sensors"] if can_read(s["deviceId"], user, devices)]
    for sensor in result["sensors"]:
        sensor["visibility"] = devices[sensor["deviceId"]]["visibility"]
    result["status"] = "matched" if result["sensors"] else "no_match"
    return result


def distance_m(a, b):
    x, y = math.radians(a["latitude"]), math.radians(b["latitude"])
    delta = math.radians(b["longitude"]-a["longitude"])
    h = math.sin((y-x)/2)**2 + math.cos(x)*math.cos(y)*math.sin(delta/2)**2
    return 6371008.8*2*math.asin(min(1, math.sqrt(h)))


class SensorIndex:
    def __init__(self, max_points=50000):
        self.points = defaultdict(list)
        self.identities = {}
        self.order = []
        self.occurrences = {}
        self.sequences = set()
        self.max_points = max_points

    def add(self, event, observed, received, sequence):
        identity = (event["device_id"], event["boot_id"], event["seq"])
        fingerprint = hashlib.sha256(encode(event)).hexdigest()
        previous = self.identities.get(identity)
        if previous is not None:
            if previous != fingerprint:
                raise ValueError("Sensor event identity conflict")
        if sequence in self.sequences:
            # Consumer redelivery of the very same retained raw record.
            return
        self.identities[identity] = fingerprint
        point = (observed, received, sequence, event)
        occurrences = self.occurrences.setdefault(identity, [])
        old = occurrences[0][1] if occurrences else None
        heappush(occurrences, (sequence, point))
        if old is None:
            insort(self.points[event["device_id"]], point)
        elif occurrences[0][1] is not old:
            self.points[event["device_id"]].remove(old)
            insort(self.points[event["device_id"]], occurrences[0][1])
        self.sequences.add(sequence)
        heappush(self.order, (sequence, identity, point))
        while len(self.order) > self.max_points:
            self._remove_oldest()

    def _remove_oldest(self):
        sequence, old_id, old_point = heappop(self.order)
        self.sequences.remove(sequence)
        occurrences = self.occurrences[old_id]
        heappop(occurrences)
        points = self.points[old_id[0]]
        points.remove(old_point)
        if occurrences:
            # One effective sample per identity, represented by its earliest
            # retained occurrence. For an unsynchronized clock this advances
            # observed/received time exactly as a fresh retained-stream replay.
            insort(points, occurrences[0][1])
        else:
            self.identities.pop(old_id, None)
            del self.occurrences[old_id]
        if not points:
            del self.points[old_id[0]]

    def retain_from(self, sequence):
        """Drop cache entries evicted from the authoritative raw stream.

        Device timestamps/redeliveries may be out of order, so retention uses
        reception sequence, not event time. Retained MQTT retries keep a sample
        available without increasing its rolling-statistic count.
        """
        while self.order and self.order[0][0] < sequence:
            self._remove_oldest()

    def match(self, envelope, devices, radius=100, max_age=300, window=60):
        location = envelope["location"]
        from .api_protocol import parse_date
        at = parse_date(location["measuredAt"])
        matched = []
        for device, points in self.points.items():
            if not points or not can_read(device, envelope["userId"], devices):
                continue
            # Infinity is only a local bisect sentinel, never serialized.
            index = bisect_right(points, (at, float("inf"), float("inf"))) - 1
            while index >= 0:
                observed, received, sequence, event = points[index]
                if at-observed > max_age:
                    index = -1
                    break
                if "position" in event and any(r["quality"] != "invalid" and
                        r.get("medium") in {"air", "water"} for r in event["readings"]):
                    break
                index -= 1
            if index < 0:
                continue
            distance = distance_m(location, event["position"])
            if distance > radius:
                continue
            readings = []
            for reading in event["readings"]:
                if reading["quality"] == "invalid" or reading.get("medium") not in {"air", "water"}:
                    continue
                values = []
                start = bisect_right(points, (observed-window,))
                for _, _, _, sample in points[start:index+1]:
                    if sample["source"] != event["source"]:
                        continue
                    for other in sample["readings"]:
                        if (other["sensor_id"], other["metric"], other["unit"], other.get("medium")) == (reading["sensor_id"], reading["metric"], reading["unit"], reading["medium"]) and other["quality"] != "invalid":
                            values.append(other["value"])
                measurements = {"sensorId": reading["sensor_id"], "medium": reading["medium"],
                    "metric": reading["metric"], "value": reading["value"], "unit": reading["unit"], "quality": reading["quality"]}
                if values:
                    measurements.update(rollingMean=round(sum(values)/len(values), 4), sampleCount=len(values), windowSeconds=window)
                readings.append(measurements)
            if not readings:
                continue
            matched.append({"deviceId": device, "locationId": event["location_id"],
                "visibility": devices[device]["visibility"], "position": event["position"],
                "distanceM": round(distance, 3), "measuredAt": iso(observed) if event["measured_at"] is not None else None,
                "receivedAt": iso(received), "observedAt": iso(observed),
                "source": event["source"], "measurements": readings})
        matched.sort(key=lambda s: (s["distanceM"], s["deviceId"]))
        result = {"schemaVersion": 1,
            "exposureId": str(uuid.uuid5(uuid.NAMESPACE_URL, "dewin/"+envelope["userId"]+"/"+location["eventId"])),
            "locationEventId": location["eventId"], "measuredAt": iso(at), "receivedAt": envelope["receivedAt"],
            "processedAt": iso(now_ts()), "position": {"latitude": location["latitude"], "longitude": location["longitude"], "accuracyM": location.get("accuracyM")},
            "status": "no_match", "matchRadiusM": radius, "maxSensorAgeSeconds": max_age, "sensors": []}
        for sensor in matched[:20]:
            result["sensors"].append(sensor)
            if len(encode(result)) > 60000:
                result["sensors"].pop()
                break
        result["status"] = "matched" if result["sensors"] else "no_match"
        return result
