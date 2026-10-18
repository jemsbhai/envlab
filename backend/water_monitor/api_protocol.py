"""Shared real-server request validation and opaque, query-scoped cursors."""
import base64
from datetime import datetime
import hashlib
import hmac
import json
from pathlib import Path
import time
import uuid

from jsonschema import Draft202012Validator

SCHEMA = json.loads(Path(__file__).with_name("api-v1.schema.json").read_text(encoding="utf-8"))


def validate(name, data):
    if len(json.dumps(data, allow_nan=False).encode()) > 16384:
        raise ValueError("Request exceeds 16 KiB")
    Draft202012Validator({"$ref": "#/$defs/"+name, "$defs": SCHEMA["$defs"]}).validate(data)


def parse_date(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00").replace("z", "+00:00"))
    if result.utcoffset() is None:
        raise ValueError("Timezone required")
    return result.timestamp()


def error(code, message, data=None, retryable=False):
    result = {"ok": False, "error": {"code": code, "message": message, "retryable": retryable}}
    if isinstance(data, dict):
        for key in ("eventId", "requestId"):
            try:
                result[key] = str(uuid.UUID(data[key]))
            except (KeyError, ValueError, TypeError, AttributeError):
                pass
    return result


class Cursors:
    def __init__(self, secret):
        if len(secret) < 32:
            raise ValueError("Cursor secret must be at least 32 characters")
        self.secret = secret.encode()

    def encode(self, value):
        payload = base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
        return payload.decode()+"."+hmac.new(self.secret, payload, hashlib.sha256).hexdigest()

    def decode(self, value, query):
        payload, signature = value.rsplit(".", 1)
        expected = hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise ValueError("Invalid cursor")
        state = json.loads(base64.urlsafe_b64decode(payload+"="*(-len(payload)%4)))
        if state["query"] != query or state["expires"] < time.time():
            raise ValueError("Invalid/expired query cursor")
        return state
