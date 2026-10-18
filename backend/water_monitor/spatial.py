"""Event-time spatial matching and current server-owned device authorization."""
from bisect import bisect_right, insort
from collections import defaultdict, deque
from copy import deepcopy
import hashlib
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
        self.order = deque()
        self.max_points = max_points

    def add(self, event, observed, received, sequence):
        identity = (event["device_id"], event["boot_id"], event["seq"])
        fingerprint = hashlib.sha256(encode(event)).hexdigest()
        previous = self.identities.get(identity)
        if previous is not None:
            if previous != fingerprint:
                raise ValueError("Sensor event identity conflict")
            return
        self.identities[identity] = fingerprint
        point = (observed, received, sequence, event)
        insort(self.points[event["device_id"]], point)
        self.order.append((identity, point))
        while len(self.order) > self.max_points:
            self._remove_oldest()

    def _remove_oldest(self):
        old_id, old_point = self.order.popleft()
        self.identities.pop(old_id, None)
        points = self.points[old_id[0]]
        points.remove(old_point)
        if not points:
            del self.points[old_id[0]]

    def retain_from(self, sequence):
        """Drop cache entries evicted from the authoritative raw stream.

        Raw messages enter this cache in stream sequence order. Device timestamps
        may be out of order, so retention uses reception sequence, not event time.
        """
        while self.order and self.order[0][1][2] < sequence:
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
            if index < 0:
                continue
            observed, received, sequence, event = points[index]
            if at-observed > max_age or "position" not in event:
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
                "distanceM": round(distance, 3), "measuredAt": event["measured_at"],
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
