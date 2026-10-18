"""Bounded, cached NOAA model guidance; never presented as local observations."""
import asyncio
from collections import OrderedDict
from copy import deepcopy
import json
import math
import time

import aiohttp

from .api_protocol import parse_date
from .contract import iso, now_ts

BASE = "https://mapservices.weather.noaa.gov/raster/rest/services/air_quality/"
PRODUCTS = (
    ("pm2_5", "µg/m³", BASE + "ndgd_apm25_hr01/ImageServer/identify"),
    ("ozone", "ppb", BASE + "ndgd_ozone_1hr_avg_time/ImageServer/identify"),
)


def measurement(data, metric, unit, url, observed):
    """Only accept finite values whose returned model interval covers the fix."""
    features = data.get("catalogItems", {}).get("features", [])
    values = data.get("properties", {}).get("Values", [])
    found = []
    for index, feature in enumerate(features):
        try:
            attrs = feature["attributes"]
            start, end, issued = (float(attrs[key])/1000 for key in
                                 ("idp_validtime", "idp_validendtime", "idp_issueddate"))
            if (not all(math.isfinite(v) for v in (start, end, issued))
                    or not start <= observed < end or issued > observed):
                continue
            raw = values[index] if len(values) == len(features) else data.get("value") if len(features) == 1 else None
            if isinstance(raw, bool):
                continue
            value = float(raw)
            if not math.isfinite(value) or value < 0:
                continue
            found.append({"metric": metric, "value": value, "unit": unit,
                          "validFrom": iso(start), "validTo": iso(end), "issuedAt": iso(issued), "sourceUrl": url})
        except (TypeError, KeyError, ValueError, OverflowError, OSError):
            continue
    return max(found, key=lambda item: item["issuedAt"]) if found else None


class NoaaAir:
    def __init__(self, session=None, *, ttl=600, max_entries=256, timeout=2,
                 clock=now_ts, cache_clock=time.monotonic):
        self.session = session
        self.owns_session = session is None
        self.ttl, self.max_entries, self.timeout = ttl, max_entries, timeout
        self.clock, self.cache_clock = clock, cache_clock
        self.cache = OrderedDict()

    async def close(self):
        if self.owns_session and self.session is not None:
            await self.session.close()

    def unavailable(self):
        return {"provider": "NOAA/NWS", "dataType": "forecast", "label": "NOAA forecast data",
                "status": "unavailable", "fetchedAt": iso(self.clock()), "measurements": [],
                "error": "Regional forecast data is temporarily unavailable"}

    async def _fetch(self, product, position, observed):
        metric, unit, url = product
        params = {"f": "json", "geometryType": "esriGeometryPoint",
                  "geometry": json.dumps({"x": position["longitude"], "y": position["latitude"],
                                          "spatialReference": {"wkid": 4326}}, separators=(",", ":")),
                  "time": str(int(observed*1000)), "returnGeometry": "false", "returnCatalogItems": "true",
                  "renderingRule": '{"rasterFunction":"None"}'}
        try:
            async with self.session.get(url, params=params, timeout=aiohttp.ClientTimeout(total=self.timeout)) as response:
                if response.status != 200:
                    return None
                data = await response.json(content_type=None)
            return measurement(data, metric, unit, url, observed)
        except Exception:
            # No coordinates, URLs containing coordinates, or upstream errors
            # are logged. Cancellation remains available for worker shutdown.
            return None

    async def enrich(self, position, measured_at):
        try:
            observed = parse_date(measured_at)
            key = (math.floor(position["latitude"]/.02), math.floor(position["longitude"]/.02),
                   math.floor(observed/3600))
            cached = self.cache.get(key)
            if cached and cached[0] > self.cache_clock():
                result = deepcopy(cached[1])
                # Validate for each fix, including exact hourly boundaries.
                result["measurements"] = [m for m in result["measurements"]
                    if parse_date(m["validFrom"]) <= observed < parse_date(m["validTo"])]
                if len(result["measurements"]) == len(cached[1]["measurements"]):
                    self.cache.move_to_end(key)
                    return result
            if self.session is None:
                self.session = aiohttp.ClientSession()
            values = await asyncio.wait_for(asyncio.gather(
                *(self._fetch(product, position, observed) for product in PRODUCTS), return_exceptions=True), timeout=4)
            measurements = [value for value in values if isinstance(value, dict)]
            result = self.unavailable()
            result["measurements"] = measurements
            result["status"] = "available" if len(measurements) == 2 else "partial" if measurements else "unavailable"
            if measurements:
                result.pop("error", None)
            if len(measurements) == 1:
                result["error"] = "Some regional forecast data is temporarily unavailable"
            self.cache[key] = (self.cache_clock()+(self.ttl if len(measurements) == 2 else min(self.ttl, 30)), deepcopy(result))
            self.cache.move_to_end(key)
            while len(self.cache) > self.max_entries:
                self.cache.popitem(last=False)
            return result
        except Exception:
            return self.unavailable()


async def enrich_exposure(value, provider):
    """Called only for a new immutable result, before its first KV create."""
    if "regionalAir" not in value:
        value["regionalAir"] = await provider.enrich(value["position"], value["measuredAt"])
    return value
