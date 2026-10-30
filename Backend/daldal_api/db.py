"""All SQL lives here. The rules it applies come from traffic.py and reports.py."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import asyncpg

from . import reports as rules
from .geo import square_around
from .traffic import MIN_TRIPS, LIVE_WINDOW_S, EdgeObservation, EdgeState, ProbePoint, blend, congestion_level

SCHEMA = Path(__file__).resolve().parent.parent / "schema.sql"


async def connect(url: str) -> asyncpg.Pool:
    pool = await asyncpg.create_pool(url, min_size=1, max_size=10)
    async with pool.acquire() as conn:
        await conn.execute(SCHEMA.read_text())
    return pool


# MARK: Probes

async def insert_probes(pool: asyncpg.Pool, trip: str, points: list[ProbePoint]) -> None:
    await pool.executemany(
        "INSERT INTO probe_points (trip, t, lat, lon, speed, accuracy) VALUES ($1, to_timestamp($2), $3, $4, $5, $6)",
        [(trip, p.t, p.lat, p.lon, p.speed_mps, p.accuracy_m) for p in points],
    )


async def claim_trips(pool: asyncpg.Pool, settle_s: int = 20) -> dict[str, list[ProbePoint]]:
    """Takes (and deletes) the points of trips whose latest batch arrived at least `settle_s` ago."""
    async with pool.acquire() as conn, conn.transaction():
        rows = await conn.fetch(
            """
            DELETE FROM probe_points WHERE trip IN (
                SELECT trip FROM probe_points GROUP BY trip
                HAVING max(received_at) < now() - make_interval(secs => $1)
                LIMIT 500
            )
            RETURNING trip::text, extract(epoch FROM t)::float8 AS t, lat, lon, speed, accuracy
            """,
            settle_s,
        )
        # Never keep raw points around: anything this old is dropped unprocessed.
        await conn.execute("DELETE FROM probe_points WHERE received_at < now() - interval '10 minutes'")
    trips: dict[str, list[ProbePoint]] = {}
    for r in rows:
        trips.setdefault(r["trip"], []).append(
            ProbePoint(t=float(r["t"]), lat=r["lat"], lon=r["lon"], speed_mps=r["speed"], accuracy_m=r["accuracy"])
        )
    return trips


# MARK: Traffic

async def apply_observations(pool: asyncpg.Pool, trip: str, obs: list[EdgeObservation], now: float, night: bool) -> None:
    if not obs:
        return
    async with pool.acquire() as conn, conn.transaction():
        existing = {
            r["edge_id"]: EdgeState(r["speed_kph"], r["freeflow_kph"], r["trips"], r["last_trip"], r["updated"])
            for r in await conn.fetch(
                """SELECT edge_id, speed_kph, freeflow_kph, trips, last_trip, extract(epoch FROM updated_at)::float8 AS updated
                   FROM traffic_live WHERE edge_id = ANY($1::bigint[]) FOR UPDATE""",
                [o.edge_id for o in obs],
            )
        }
        rows = []
        for o in obs:
            state = blend(existing.get(o.edge_id), o, trip, now, night)
            line = "LINESTRING(" + ",".join(f"{lon} {lat}" for lat, lon in o.geometry) + ")"
            rows.append((o.edge_id, o.way_id, line, o.length_m, o.valhalla_kph, state.freeflow_kph,
                         state.speed_kph, state.trips, state.last_trip, now))
        await conn.executemany(
            """
            INSERT INTO traffic_live (edge_id, way_id, geom, length_m, valhalla_kph, freeflow_kph, speed_kph,
                                      trips, last_trip, updated_at)
            VALUES ($1, $2, ST_GeomFromText($3, 4326), $4, $5, $6, $7, $8, $9, to_timestamp($10))
            ON CONFLICT (edge_id) DO UPDATE SET
                freeflow_kph = EXCLUDED.freeflow_kph, speed_kph = EXCLUDED.speed_kph,
                trips = EXCLUDED.trips, last_trip = EXCLUDED.last_trip, updated_at = EXCLUDED.updated_at
            """,
            rows,
        )


async def traffic_geojson(pool: asyncpg.Pool, bbox: tuple[float, float, float, float]) -> dict:
    rows = await pool.fetch(
        """
        SELECT edge_id, ST_AsGeoJSON(geom) AS geom, speed_kph, freeflow_kph
        FROM traffic_live
        WHERE geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
          AND trips >= $5 AND updated_at > now() - make_interval(secs => $6)
          AND speed_kph < freeflow_kph * 0.75
        """,
        *bbox, MIN_TRIPS, LIVE_WINDOW_S,
    )
    features = [
        {
            "type": "Feature",
            "geometry": json.loads(r["geom"]),
            "properties": {
                "level": congestion_level(r["speed_kph"], r["freeflow_kph"]),
                "speed_kph": round(r["speed_kph"]),
            },
        }
        for r in rows
    ]
    return {"type": "FeatureCollection", "features": features}


async def live_states(pool: asyncpg.Pool, edge_ids: list[int]) -> dict[int, EdgeState]:
    rows = await pool.fetch(
        """SELECT edge_id, speed_kph, freeflow_kph, trips, last_trip, extract(epoch FROM updated_at)::float8 AS updated
           FROM traffic_live WHERE edge_id = ANY($1::bigint[])""",
        edge_ids,
    )
    return {r["edge_id"]: EdgeState(r["speed_kph"], r["freeflow_kph"], r["trips"], r["last_trip"], r["updated"]) for r in rows}


# MARK: Reports

def _report(r: asyncpg.Record) -> rules.Report:
    return rules.Report(
        id=str(r["id"]), type=r["type"], lat=r["lat"], lon=r["lon"], heading=r["heading"], reporter=r["reporter"],
        up=r["up"], down=r["down"], created_at=r["created_at"], expires_at=r["expires_at"],
    )


_REPORT_COLUMNS = "id, type, ST_Y(geom) AS lat, ST_X(geom) AS lon, heading, reporter, up, down, created_at, expires_at"


async def create_report(pool: asyncpg.Pool, type_: str, lat: float, lon: float, heading: float | None,
                        reporter: str) -> tuple[str, bool]:
    """Returns (report id, merged). A duplicate of a fresh nearby report confirms it instead."""
    now = datetime.now(timezone.utc)
    async with pool.acquire() as conn, conn.transaction():
        nearby = await conn.fetch(
            f"""SELECT {_REPORT_COLUMNS} FROM reports
                WHERE NOT removed AND type = $1 AND expires_at > now()
                  AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, $4)
                FOR UPDATE""",
            type_, lat, lon, rules.DUPLICATE_RADIUS_M,
        )
        for r in map(_report, nearby):
            if rules.is_duplicate(r, type_, lat, lon, heading, now):
                if r.reporter != reporter:
                    await _vote(conn, r, reporter, still_there=True, now=now)
                return r.id, True
        row = await conn.fetchrow(
            """INSERT INTO reports (type, geom, heading, reporter, expires_at)
               VALUES ($1, ST_SetSRID(ST_MakePoint($3, $2), 4326), $4, $5, $6) RETURNING id""",
            type_, lat, lon, heading, reporter, rules.expiry(type_, now),
        )
        await conn.execute("INSERT INTO reporters (reporter) VALUES ($1) ON CONFLICT DO NOTHING", reporter)
        return str(row["id"]), False


async def vote(pool: asyncpg.Pool, report_id: str, voter: str, still_there: bool) -> bool:
    """Records a vote. Returns False if the report doesn't exist, is gone, or the voter already voted."""
    now = datetime.now(timezone.utc)
    async with pool.acquire() as conn, conn.transaction():
        row = await conn.fetchrow(
            f"SELECT {_REPORT_COLUMNS} FROM reports WHERE id = $1 AND NOT removed FOR UPDATE", report_id
        )
        if row is None:
            return False
        report = _report(row)
        if report.reporter == voter:
            return False
        return await _vote(conn, report, voter, still_there, now)


async def _vote(conn: asyncpg.Connection, report: rules.Report, voter: str, still_there: bool, now: datetime) -> bool:
    inserted = await conn.fetchval(
        """INSERT INTO report_votes (report_id, voter, still_there) VALUES ($1, $2, $3)
           ON CONFLICT DO NOTHING RETURNING true""",
        report.id, voter, still_there,
    )
    if not inserted:
        return False
    was_confirmed = report.up >= 2
    remove = rules.apply_vote(report, still_there, now)
    await conn.execute(
        "UPDATE reports SET up = $2, down = $3, expires_at = $4, removed = $5 WHERE id = $1",
        report.id, report.up, report.down, report.expires_at, remove,
    )
    # The reporter's record: first confirmation counts once; a removal by votes counts against them.
    if still_there and not was_confirmed and report.up >= 2:
        await conn.execute("UPDATE reporters SET confirmed = confirmed + 1 WHERE reporter = $1", report.reporter)
    if remove:
        await conn.execute("UPDATE reporters SET rejected = rejected + 1 WHERE reporter = $1", report.reporter)
    return True


async def active_reports(pool: asyncpg.Pool, bbox: tuple[float, float, float, float]) -> list[dict]:
    now = datetime.now(timezone.utc)
    rows = await pool.fetch(
        f"""SELECT {_REPORT_COLUMNS}, coalesce(p.confirmed, 0) AS confirmed, coalesce(p.rejected, 0) AS rejected
            FROM reports r LEFT JOIN reporters p USING (reporter)
            WHERE NOT removed AND expires_at > now() AND geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)
            LIMIT 500""",
        *bbox,
    )
    result = []
    for row in rows:
        report = _report(row)
        if rules.visible(report, rules.reporter_trust(row["confirmed"], row["rejected"]), now):
            result.append({
                "id": report.id, "type": report.type, "lat": report.lat, "lon": report.lon,
                "heading": report.heading, "confirmations": report.up,
                "reported_at": report.created_at.isoformat(), "expires_at": report.expires_at.isoformat(),
            })
    return result


async def closure_polygons(pool: asyncpg.Pool) -> list[list[list[float]]]:
    """Confirmed road closures as small squares for Valhalla's `exclude_polygons`."""
    now = datetime.now(timezone.utc)
    rows = await pool.fetch(
        f"SELECT {_REPORT_COLUMNS} FROM reports WHERE type = 'closure' AND NOT removed AND expires_at > now()"
    )
    return [square_around(r.lat, r.lon, 20) for r in map(_report, rows) if rules.affects_routing(r, now)]
