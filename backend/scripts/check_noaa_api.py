"""Verify real NOAA forecast enrichment and its immutable Socket.IO history."""
import argparse
import asyncio
from datetime import datetime, timedelta
import json
import math
import uuid

from check_live_api import DemoClient, health, position, validate


def date(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


async def run(args):
    await health(args.url)
    client = DemoClient(args.url, "0", "websocket")
    try:
        await client.connect()
        fix = position(latitude=args.latitude, longitude=args.longitude)
        ack = await client.call("location:update", fix)
        validate("LocationAck", ack)
        assert ack["ok"], "Location was not persisted"
        result = await client.exposure(fix["eventId"])
        regional = result.get("regionalAir", {})
        assert regional.get("provider") == "NOAA/NWS", "NOAA provider missing"
        assert regional.get("dataType") == "forecast" and regional.get("label") == "NOAA forecast data"
        assert regional.get("status") == "available", "Both NOAA forecasts must be available for this live check"
        readings = {item["metric"]: item for item in regional["measurements"]}
        assert readings.keys() == {"pm2_5", "ozone"}
        for metric, unit in (("pm2_5", "µg/m³"), ("ozone", "ppb")):
            item = readings[metric]
            assert item["unit"] == unit and math.isfinite(item["value"]) and item["value"] >= 0
            assert date(item["validFrom"]) <= date(fix["measuredAt"]) < date(item["validTo"])
            assert date(item["issuedAt"]) <= date(fix["measuredAt"])
            assert item["sourceUrl"].startswith("https://mapservices.weather.noaa.gov/")
        observed = date(fix["measuredAt"])
        query = {"requestId": str(uuid.uuid4()), "from": (observed-timedelta(seconds=1)).isoformat(),
                 "to": (observed+timedelta(seconds=1)).isoformat(), "limit": 200}
        page = await client.call("exposure:history", query)
        validate("HistoryPage", page)
        saved = next(item for item in page["items"] if item["exposureId"] == result["exposureId"])
        assert saved["regionalAir"] == regional, "History changed the stored NOAA snapshot"
        retry = await client.call("location:update", fix)
        assert retry["duplicate"] and retry["receivedAt"] == ack["receivedAt"]
        print("PASS token 0, real NOAA PM2.5/ozone, forecast labels/units/validity, immutable history, and duplicate receipt")
        print(json.dumps(regional, ensure_ascii=False, indent=2))
    finally:
        await client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://dewin-api.cbnsndwch.dev")
    parser.add_argument("--latitude", type=float, default=25.7617)
    parser.add_argument("--longitude", type=float, default=-80.1918)
    asyncio.run(run(parser.parse_args()))
