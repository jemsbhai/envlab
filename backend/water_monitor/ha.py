import hashlib
import json
import math
import re

from .contract import iso


def entity_key(row, aggregate=False):
    parts = [row["device_id"], row["sensor_id"], row["metric"], "mean" if aggregate else "value"]
    suffix = hashlib.sha256(json.dumps(parts).encode()).hexdigest()[:10]
    return "env_" + "_".join(parts) + "_" + suffix


def messages(row, mean, count, now, expiry=30, window=60):
    """No historical observation can turn into a fresh current state on replay."""
    remaining = min(expiry, math.ceil(expiry - (now - row["observed_at"])))
    if remaining <= 0:
        return []
    output = []
    base = f"env/ha/{row['device_id']}/{row['sensor_id']}/{row['metric']}"
    for aggregate in (False, True):
        if aggregate and (mean is None or count == 0):
            continue
        key = entity_key(row, aggregate)
        topic = base + ("/mean" if aggregate else "/state")
        config = {
            "name": f"{row['sensor_id']} {row['metric']}" + (f" mean {window}s" if aggregate else ""),
            "unique_id": key,
            "default_entity_id": "sensor." + re.sub("[^a-z0-9_]", "_", key),
            "state_topic": topic,
            "value_template": "{{ value_json.value }}",
            "json_attributes_topic": topic,
            "unit_of_measurement": row["unit"],
            "state_class": "measurement",
            "expire_after": remaining,
            "availability_topic": "env/ha/pipeline/availability",
            "qos": 1,
            "device": {"identifiers": [f"env_{row['device_id']}"], "name": row["device_id"]},
            "origin": {"name": "Team Zero telemetry", "sw_version": "0.1.0"},
        }
        if row["metric"] == "temperature" and row["unit"] == "°C":
            config["device_class"] = "temperature"
        elif row["metric"] == "humidity" and row["unit"] == "%":
            config["device_class"] = "humidity"
        if not row["unit"]:
            config.pop("unit_of_measurement")
        state = {
            "value": round(mean if aggregate else row["value"], 4),
            "source": row["source"], "location_id": row["location_id"], "quality": row["quality"],
            "measured_at": iso(row["observed_at"]), "received_at": iso(row["received_at"]),
        }
        if aggregate:
            state.update(window_seconds=window, sample_count=count)
        output.append((f"homeassistant/sensor/{key}/config", config, True))
        output.append((topic, state, False))
    return output
