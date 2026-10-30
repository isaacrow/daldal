"""Turns raw probe points into live traffic, then forgets them. Run one instance: `python -m daldal_api.worker`."""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime

from . import config, db
from .traffic import is_night, observations, split_trip
from .valhalla import Valhalla

log = logging.getLogger("daldal.worker")


async def process_once(pool, valhalla: Valhalla, settings: config.Settings) -> int:
    trips = await db.claim_trips(pool)
    matched = 0
    for trip, points in trips.items():
        for chunk in split_trip(points):
            try:
                match = await valhalla.match_trace(chunk)
            except Exception as error:  # A bad trace (e.g. all points off-road) must not stop the loop.
                log.warning("map matching failed: %s", type(error).__name__)
                continue
            obs = observations(match, chunk)
            now = time.time()
            night = is_night(datetime.fromtimestamp(now, settings.timezone))
            await db.apply_observations(pool, trip, obs, now, night)
            matched += len(obs)
    return matched


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    settings = config.load()
    pool = await db.connect(settings.database_url)
    valhalla = Valhalla(settings.valhalla_url)
    while True:
        started = time.monotonic()
        try:
            edges = await process_once(pool, valhalla, settings)
            if edges:
                log.info("updated %d road edges", edges)
        except Exception:
            log.exception("worker pass failed")
        await asyncio.sleep(max(0.0, 15 - (time.monotonic() - started)))


if __name__ == "__main__":
    asyncio.run(main())
