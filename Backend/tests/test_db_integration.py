"""End-to-end against a real PostGIS. Skipped unless DALDAL_TEST_DATABASE_URL is set, e.g.

    docker compose up -d db
    DALDAL_TEST_DATABASE_URL=postgresql://daldal:daldal@localhost:5432/daldal pytest
"""
import json
import os
import time
import uuid
from pathlib import Path

import pytest

from daldal_api import db
from daldal_api.traffic import ProbePoint, observations

URL = os.environ.get("DALDAL_TEST_DATABASE_URL")
pytestmark = pytest.mark.skipif(not URL, reason="set DALDAL_TEST_DATABASE_URL to run database tests")
FIXTURES = Path(__file__).parent / "fixtures"
BAGHDAD = (44.30, 33.25, 44.45, 33.40)


@pytest.fixture
async def pool():
    pool = await db.connect(URL)
    async with pool.acquire() as conn:
        await conn.execute("TRUNCATE probe_points, traffic_live, reports, report_votes, reporters")
    yield pool
    await pool.close()


async def test_traffic_appears_only_after_two_trips(pool):
    match = json.loads((FIXTURES / "baghdad_trace_attributes.json").read_text(encoding="utf-8"))
    raw = json.loads((FIXTURES / "baghdad_trace_points.json").read_text(encoding="utf-8"))
    points = [ProbePoint(p["time"], p["lat"], p["lon"], p["speed"], 5) for p in raw]
    obs = observations(match, points)
    now = time.time()

    await db.apply_observations(pool, "trip-a", obs, now, night=False)
    assert (await db.traffic_geojson(pool, BAGHDAD))["features"] == [], "one car is never shown"

    await db.apply_observations(pool, "trip-b", obs, now + 30, night=False)
    features = (await db.traffic_geojson(pool, BAGHDAD))["features"]
    assert features, "two trips at 12 km/h show as congestion"
    assert all(f["properties"]["level"] >= 1 for f in features)
    assert all(f["geometry"]["type"] == "LineString" for f in features)


async def test_probes_are_claimed_once_and_deleted(pool):
    trip = str(uuid.uuid4())
    t = time.time()
    await db.insert_probes(pool, trip, [ProbePoint(t + i, 33.31, 44.39, 5, 5) for i in range(5)])
    async with pool.acquire() as conn:
        await conn.execute("UPDATE probe_points SET received_at = now() - interval '1 minute'")
    claimed = await db.claim_trips(pool)
    assert len(claimed[trip]) == 5
    assert await db.claim_trips(pool) == {}
    assert await pool.fetchval("SELECT count(*) FROM probe_points") == 0


async def test_report_lifecycle(pool):
    report_id, merged = await db.create_report(pool, "accident", 33.3128, 44.3915, 90, "alice")
    assert not merged
    same_id, merged = await db.create_report(pool, "accident", 33.3132, 44.3916, 95, "bob")
    assert merged and same_id == report_id, "bob's report confirms alice's"

    [shown] = await db.active_reports(pool, BAGHDAD)
    assert shown["confirmations"] == 2

    assert not await db.vote(pool, report_id, "bob", False), "bob already voted"
    assert await db.vote(pool, report_id, "carol", False)
    assert await db.vote(pool, report_id, "dave", False)
    assert await db.active_reports(pool, BAGHDAD) == [], "two 'gone' votes outweigh two confirmations"


async def test_closures_route_around_only_when_confirmed(pool):
    report_id, _ = await db.create_report(pool, "closure", 33.3128, 44.3915, None, "alice")
    assert await db.closure_polygons(pool) == []
    await db.vote(pool, report_id, "bob", True)
    [ring] = await db.closure_polygons(pool)
    assert ring[0] == ring[-1]
