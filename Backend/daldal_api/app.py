"""Daldal live API: anonymous traffic probes, driver reports, live ETAs, closures."""
from __future__ import annotations

import hashlib
import re
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

from . import config, db
from .geo import in_iraq, parse_bbox
from .reports import TYPES
from .traffic import ProbePoint, route_delay_s
from .valhalla import Valhalla


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = config.load()
    app.state.settings = settings
    app.state.pool = await db.connect(settings.database_url)
    app.state.valhalla = Valhalla(settings.valhalla_url)
    yield
    await app.state.pool.close()


app = FastAPI(title="Daldal Live", version="1", lifespan=lifespan, docs_url=None, redoc_url=None)

# MARK: Identity and limits

_INSTALL_ID = re.compile(r"^[0-9a-fA-F-]{36}$")
_buckets: dict[tuple[str, str], deque[float]] = defaultdict(deque)


def device(request: Request, x_daldal_install: Annotated[str, Header()]) -> str:
    """Pseudonymous reporter id: a salted hash of the app's random install id. Never stored raw."""
    if not _INSTALL_ID.match(x_daldal_install):
        raise HTTPException(400, "bad install id")
    salt = request.app.state.settings.id_salt
    return hashlib.sha256(f"{salt}:{x_daldal_install.lower()}".encode()).hexdigest()[:32]


def rate_limit(key: str, scope: str, per_minute: int) -> None:
    """Sliding-window limit per install. In-process: run one API instance, or move this to Redis."""
    now = time.monotonic()
    bucket = _buckets[(scope, key)]
    while bucket and now - bucket[0] > 60:
        bucket.popleft()
    if len(bucket) >= per_minute:
        raise HTTPException(429, "slow down")
    bucket.append(now)


def bbox_param(bbox: str = Query(..., description="min_lon,min_lat,max_lon,max_lat")) -> tuple[float, float, float, float]:
    try:
        return parse_bbox(bbox)
    except ValueError as error:
        raise HTTPException(400, str(error)) from None


# MARK: Probes

class Probe(BaseModel):
    t: float
    lat: float
    lon: float
    speed: float | None = Field(None, ge=0, le=70)  # m/s; 70 m/s = 252 km/h
    accuracy: float = Field(..., gt=0)


class ProbeBatch(BaseModel):
    trip: str = Field(..., pattern=r"^[0-9a-fA-F-]{36}$")
    points: list[Probe] = Field(..., max_length=120)


@app.post("/v1/probes", status_code=202)
async def post_probes(batch: ProbeBatch, request: Request) -> dict:
    # Probes carry no install id on purpose: only the per-trip random token links points together.
    rate_limit(batch.trip, "probes", 12)
    now = time.time()
    points = [
        ProbePoint(t=p.t, lat=p.lat, lon=p.lon, speed_mps=p.speed, accuracy_m=p.accuracy)
        for p in batch.points
        if p.accuracy <= 50 and in_iraq(p.lat, p.lon) and now - 600 <= p.t <= now + 60
    ]
    if points:
        await db.insert_probes(request.app.state.pool, batch.trip, points)
    return {"accepted": len(points)}


# MARK: Traffic and ETA

@app.get("/v1/traffic")
async def get_traffic(request: Request, bbox: Annotated[tuple, Depends(bbox_param)]) -> dict:
    return await db.traffic_geojson(request.app.state.pool, bbox)


class RouteShape(BaseModel):
    id: str = Field(..., max_length=64)
    shape: str = Field(..., max_length=200_000)  # polyline6


class EtaRequest(BaseModel):
    routes: list[RouteShape] = Field(..., min_length=1, max_length=4)


@app.post("/v1/eta")
async def post_eta(body: EtaRequest, request: Request) -> dict:
    """Live delay per route. The app adds it to the route's own duration to compare options fairly."""
    valhalla: Valhalla = request.app.state.valhalla
    now = time.time()
    results = []
    for route in body.routes:
        try:
            edges = await valhalla.route_edges(route.shape)
        except Exception:
            results.append({"id": route.id, "delay_s": 0, "coverage": 0})
            continue
        live = await db.live_states(request.app.state.pool, [e.edge_id for e in edges])
        delay, coverage = route_delay_s(edges, live, now)
        results.append({"id": route.id, "delay_s": round(delay), "coverage": round(coverage, 3)})
    return {"routes": results}


# MARK: Reports

class NewReport(BaseModel):
    type: Literal["jam", "accident", "police", "hazard", "flood", "closure"]
    lat: float
    lon: float
    heading: float | None = Field(None, ge=0, lt=360)


@app.post("/v1/reports", status_code=201)
async def post_report(body: NewReport, request: Request, reporter: Annotated[str, Depends(device)]) -> dict:
    assert body.type in TYPES
    if not in_iraq(body.lat, body.lon):
        raise HTTPException(422, "outside Iraq")
    rate_limit(reporter, "reports", 6)
    report_id, merged = await db.create_report(request.app.state.pool, body.type, body.lat, body.lon, body.heading, reporter)
    return {"id": report_id, "merged": merged}


@app.get("/v1/reports")
async def get_reports(request: Request, bbox: Annotated[tuple, Depends(bbox_param)]) -> dict:
    return {"reports": await db.active_reports(request.app.state.pool, bbox)}


class Vote(BaseModel):
    still_there: bool


@app.post("/v1/reports/{report_id}/votes")
async def post_vote(report_id: str, body: Vote, request: Request, voter: Annotated[str, Depends(device)]) -> dict:
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", report_id):
        raise HTTPException(404, "no such report")
    rate_limit(voter, "votes", 30)
    counted = await db.vote(request.app.state.pool, report_id, voter, body.still_there)
    return {"counted": counted}


@app.get("/v1/closures")
async def get_closures(request: Request) -> dict:
    return {"polygons": await db.closure_polygons(request.app.state.pool)}


@app.get("/healthz")
async def health() -> dict:
    return {"ok": True}
