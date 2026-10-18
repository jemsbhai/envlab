from datetime import datetime, timezone
import json
import math
from importlib.resources import files

from jsonschema import Draft202012Validator

SCHEMA = json.loads(files("water_monitor").joinpath("telemetry.schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA)
RAW_SUBJECT = "env.v1.*.telemetry"
STREAM = "ENV_RAW"
DURABLE = "ha-processor-v1"


def now_ts():
    return datetime.now(timezone.utc).timestamp()


def iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat().replace("+00:00", "Z")


def reject_nonfinite(value):
    raise ValueError(f"non-finite JSON number: {value}")


def validate(payload, subject, received_at):
    if len(payload) > 16384:
        raise ValueError("telemetry exceeds 16 KiB")
    event = json.loads(payload, parse_constant=reject_nonfinite)
    VALIDATOR.validate(event)
    if subject != f"env.v1.{event['device_id']}.telemetry":
        raise ValueError("device_id does not match MQTT topic")
    observed_at = received_at
    if event["measured_at"] is not None:
        try:
            measured = datetime.fromisoformat(event["measured_at"].replace("Z", "+00:00"))
            if measured.utcoffset() is None:
                raise ValueError("timestamp needs a timezone")
            observed_at = measured.timestamp()
        except (ValueError, TypeError, OverflowError) as error:
            raise ValueError("measured_at must be an ISO 8601 timestamp with timezone, or null") from error
    if observed_at > received_at + 60:
        raise ValueError("device clock is more than 60 seconds ahead of broker receive time")
    seen = set()
    for reading in event["readings"]:
        if not math.isfinite(reading["value"]):
            raise ValueError("non-finite reading")
        key = reading["sensor_id"], reading["metric"]
        if key in seen:
            raise ValueError("duplicate sensor/metric in one packet")
        seen.add(key)
        reading.setdefault("quality", "ok")
        if reading["metric"] == "temperature":
            if reading["unit"] in ("F", "°F"):
                reading["value"] = (reading["value"] - 32) * 5 / 9
                reading["unit"] = "°C"
            elif reading["unit"] == "C":
                reading["unit"] = "°C"
    return event, observed_at
