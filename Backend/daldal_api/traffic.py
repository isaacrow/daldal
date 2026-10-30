"""Live traffic from anonymous GPS probes.

Pipeline: a trip's probe points are map-matched with Valhalla `trace_attributes`; each matched road
edge gets the median of the phones' own GPS speeds (Doppler speed, accurate to ~1 km/h); that observation
is blended into the edge's live speed. Nothing here touches the database.
"""
from __future__ import annotations

import math
import statistics
from dataclasses import dataclass
from datetime import datetime

from .geo import decode_polyline

# A segment is only shown, or used for ETAs, once this many different trips have reported on it.
# This is also a privacy rule: one car's movements are never visible on the map.
MIN_TRIPS = 2
LIVE_WINDOW_S = 15 * 60
# Live speed forgets old observations with this time constant.
BLEND_TAU_S = 5 * 60
MIN_SPEED_KPH = 3.0


@dataclass(frozen=True)
class ProbePoint:
    t: float  # unix seconds
    lat: float
    lon: float
    speed_mps: float | None
    accuracy_m: float


@dataclass(frozen=True)
class EdgeObservation:
    edge_id: int
    way_id: int
    length_m: float
    valhalla_kph: float
    observed_kph: float
    samples: int
    geometry: list[tuple[float, float]]


@dataclass
class EdgeState:
    speed_kph: float
    freeflow_kph: float
    trips: int
    last_trip: str
    updated_at: float  # unix seconds


def split_trip(points: list[ProbePoint], max_gap_s: float = 60, min_points: int = 4) -> list[list[ProbePoint]]:
    """Splits a trip where the phone stopped reporting (tunnel, app closed), so matching doesn't bridge gaps."""
    chunks, current = [], []
    for p in sorted(points, key=lambda p: p.t):
        if current and p.t - current[-1].t > max_gap_s:
            chunks.append(current)
            current = []
        current.append(p)
    chunks.append(current)
    return [c for c in chunks if len(c) >= min_points]


def trace_request(points: list[ProbePoint]) -> dict:
    return {
        "shape": [{"lat": p.lat, "lon": p.lon, "time": int(p.t)} for p in points],
        "costing": "auto",
        "shape_match": "map_snap",
        "use_timestamps": True,
        "filters": {
            "attributes": [
                "edge.id", "edge.way_id", "edge.length", "edge.speed",
                "edge.begin_shape_index", "edge.end_shape_index",
                "shape", "matched.edge_index", "matched.type",
            ],
            "action": "include",
        },
    }


def observations(match: dict, points: list[ProbePoint]) -> list[EdgeObservation]:
    """Turns a Valhalla trace_attributes reply into one speed observation per matched edge."""
    edges = match.get("edges") or []
    matched = match.get("matched_points") or []
    shape = decode_polyline(match["shape"]) if match.get("shape") else []

    speeds: dict[int, list[float]] = {}
    for point, m in zip(points, matched):
        index = m.get("edge_index")
        if m.get("type") == "unmatched" or index is None or not (0 <= index < len(edges)):
            continue
        if point.speed_mps is None or point.speed_mps < 0:
            continue
        speeds.setdefault(index, []).append(point.speed_mps * 3.6)

    result = []
    for index, values in speeds.items():
        edge = edges[index]
        if "id" not in edge or "speed" not in edge:
            continue
        begin, end = edge.get("begin_shape_index", 0), edge.get("end_shape_index", 0)
        geometry = shape[begin:end + 1] if shape else []
        if len(geometry) < 2:
            continue
        result.append(EdgeObservation(
            edge_id=int(edge["id"]),
            way_id=int(edge.get("way_id", 0)),
            length_m=float(edge.get("length", 0)) * 1000,  # Valhalla reports km
            valhalla_kph=float(edge["speed"]),
            observed_kph=statistics.median(values),
            samples=len(values),
            geometry=geometry,
        ))
    return result


def blend(state: EdgeState | None, obs: EdgeObservation, trip: str, now: float, night: bool) -> EdgeState:
    """Folds one observation into an edge's live state.

    Free-flow speed starts at Valhalla's estimate (from OSM tags, often wrong in Iraq) and learns:
    it rises when cars are seen going faster, and settles toward night-time speeds, when roads are empty.
    """
    if state is None or now - state.updated_at > LIVE_WINDOW_S:
        freeflow = state.freeflow_kph if state else obs.valhalla_kph
        state = EdgeState(speed_kph=obs.observed_kph, freeflow_kph=freeflow, trips=0, last_trip="", updated_at=now)
    else:
        weight = math.exp(-(now - state.updated_at) / BLEND_TAU_S)
        state.speed_kph = weight * state.speed_kph + (1 - weight) * obs.observed_kph

    if obs.observed_kph > state.freeflow_kph:
        state.freeflow_kph = 0.9 * state.freeflow_kph + 0.1 * obs.observed_kph
    elif night:
        state.freeflow_kph = 0.95 * state.freeflow_kph + 0.05 * obs.observed_kph

    if trip != state.last_trip:
        state.trips += 1
        state.last_trip = trip
    state.updated_at = now
    return state


def congestion_level(speed_kph: float, freeflow_kph: float) -> int:
    """0 free, 1 slow, 2 heavy, 3 standstill."""
    if freeflow_kph <= 0:
        return 0
    ratio = speed_kph / freeflow_kph
    if ratio >= 0.75:
        return 0
    if ratio >= 0.5:
        return 1
    if ratio >= 0.25:
        return 2
    return 3


def is_live(state: EdgeState, now: float) -> bool:
    return state.trips >= MIN_TRIPS and now - state.updated_at <= LIVE_WINDOW_S


@dataclass(frozen=True)
class RouteEdge:
    edge_id: int
    length_m: float
    valhalla_kph: float


def route_delay_s(edges: list[RouteEdge], live: dict[int, EdgeState], now: float) -> tuple[float, float]:
    """Extra seconds a route takes right now versus Valhalla's estimate, and the share of it we have data for.

    Only live edges contribute, so with no data the delay is 0 and the route's own ETA stands.
    """
    delay = 0.0
    covered = 0.0
    total = sum(e.length_m for e in edges) or 1.0
    for e in edges:
        state = live.get(e.edge_id)
        if state is None or not is_live(state, now) or e.valhalla_kph <= 0:
            continue
        expected = e.length_m / (e.valhalla_kph / 3.6)
        actual = e.length_m / (max(state.speed_kph, MIN_SPEED_KPH) / 3.6)
        delay += actual - expected
        covered += e.length_m
    return delay, covered / total


def is_night(local: datetime) -> bool:
    return 0 <= local.hour < 5
