import asyncio
from copy import deepcopy
import json
import unittest

from water_monitor.contract import iso
from water_monitor.noaa import NoaaAir, PRODUCTS, enrich_exposure, measurement


def response(at, value="6.85", start=None, end=None):
    start = int(at//3600*3600) if start is None else start
    end = start+3600 if end is None else end
    return {"value": value, "properties": {"Values": [value]}, "catalogItems": {"features": [
        {"attributes": {"idp_validtime": start*1000, "idp_validendtime": end*1000,
                        "idp_issueddate": (start-3600)*1000}}]}}


class FakeResponse:
    status = 200

    def __init__(self, value):
        self.value = value

    async def __aenter__(self):
        if isinstance(self.value, Exception):
            raise self.value
        return self

    async def __aexit__(self, *args):
        pass

    async def json(self, **kwargs):
        return deepcopy(self.value)


class FakeSession:
    def __init__(self, values):
        self.values, self.calls = values, []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return FakeResponse(self.values[0 if "apm25" in url else 1])


class NoaaTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.at = 1800000030
        self.tick = 0
        self.position = {"latitude": 25.7617, "longitude": -80.1918}
        self.session = FakeSession([response(self.at), response(self.at, "44.9994")])
        self.provider = NoaaAir(self.session, clock=lambda: self.at, cache_clock=lambda: self.tick)

    async def test_success_uses_explicit_fix_time_raw_values_units_and_validity(self):
        result = await self.provider.enrich(self.position, iso(self.at))
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["dataType"], "forecast")
        self.assertEqual([(m["metric"], m["value"], m["unit"]) for m in result["measurements"]],
                         [("pm2_5", 6.85, "µg/m³"), ("ozone", 44.9994, "ppb")])
        for url, request in self.session.calls:
            self.assertTrue(url.startswith("https://mapservices.weather.noaa.gov/"))
            self.assertEqual(request["params"]["time"], str(self.at*1000))
            self.assertEqual(json.loads(request["params"]["geometry"])["spatialReference"]["wkid"], 4326)
            self.assertEqual(json.loads(request["params"]["renderingRule"]), {"rasterFunction": "None"})
            self.assertEqual(request["timeout"].total, 2)

    async def test_partial_timeout_and_nodata_never_become_zero(self):
        self.session.values[1] = TimeoutError()
        result = await self.provider.enrich(self.position, iso(self.at))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(len(result["measurements"]), 1)
        self.session.values[0] = response(self.at, "NoData")
        self.tick = 31  # Failed/partial results retry after a short negative-cache TTL.
        result = await self.provider.enrich(self.position, iso(self.at))
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["measurements"], [])

    async def test_stale_and_exact_end_boundary_are_rejected(self):
        product = PRODUCTS[0]
        self.assertIsNone(measurement(response(self.at, start=self.at-7200, end=self.at-3600), *product, self.at))
        self.assertIsNone(measurement(response(self.at, start=self.at-3600, end=self.at), *product, self.at))
        self.assertIsNone(measurement(response(self.at, "NaN"), *product, self.at))
        self.assertIsNone(measurement(response(self.at, "Infinity"), *product, self.at))

    async def test_cache_is_bounded_hour_scoped_and_returned_snapshots_are_independent(self):
        result = await self.provider.enrich(self.position, iso(self.at))
        result["measurements"].clear()
        cached = await self.provider.enrich(self.position, iso(self.at+1))
        self.assertEqual(len(cached["measurements"]), 2)
        self.assertEqual(len(self.session.calls), 2)
        self.tick = 601
        await self.provider.enrich(self.position, iso(self.at))
        self.assertEqual(len(self.session.calls), 4)
        self.provider.max_entries = 2
        for hour in range(1, 4):
            await self.provider.enrich(self.position, iso(self.at+hour*3600))
        self.assertEqual(len(self.provider.cache), 2)

    async def test_stored_regional_snapshot_is_not_recomputed_or_mutated_on_retry(self):
        value = {"position": self.position, "measuredAt": iso(self.at), "status": "no_match", "sensors": []}
        await enrich_exposure(value, self.provider)
        persisted = deepcopy(value)
        self.tick = 9999
        self.session.values = [TimeoutError(), TimeoutError()]
        await enrich_exposure(value, self.provider)
        self.assertEqual(value, persisted)
        self.assertEqual(value["status"], "no_match")
        self.assertEqual(value["sensors"], [])
        self.assertEqual(len(self.session.calls), 2)


if __name__ == "__main__":
    unittest.main()
