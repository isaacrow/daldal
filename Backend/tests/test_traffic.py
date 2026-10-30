import json
from pathlib import Path

import pytest

from daldal_api.traffic import (
    MIN_TRIPS, EdgeObservation, EdgeState, ProbePoint, RouteEdge, blend, congestion_level, is_live,
    observations, route_delay_s, split_trip,
)

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def baghdad():
    """A simulated drive along a real Baghdad route (12 km/h for 3 km, then 45 km/h), map-matched by Valhalla."""
    match = json.loads((FIXTURES / "baghdad_trace_attributes.json").read_text(encoding="utf-8"))
    raw = json.loads((FIXTURES / "baghdad_trace_points.json").read_text(encoding="utf-8"))
    points = [ProbePoint(t=p["time"], lat=p["lat"], lon=p["lon"], speed_mps=p["speed"], accuracy_m=5) for p in raw]
    return match, points


def test_observations_from_real_match(baghdad):
    match, points = baghdad
    obs = observations(match, points)
    assert len(obs) > 20
    assert len({o.edge_id for o in obs}) == len(obs), "one observation per edge"
    for o in obs:
        assert o.length_m > 0 and o.valhalla_kph > 0
        assert len(o.geometry) >= 2
        # Every point was driven at either 12 or 45 km/h, so each edge's median is one of those.
        assert o.observed_kph == pytest.approx(12, abs=0.1) or o.observed_kph == pytest.approx(45, abs=0.1)
    slow = [o for o in obs if o.observed_kph < 20]
    fast = [o for o in obs if o.observed_kph > 40]
    assert slow and fast


def test_observation_geometry_is_on_the_route(baghdad):
    match, points = baghdad
    obs = observations(match, points)
    # All matched geometry lies inside central Baghdad, between Tahrir and Kadhimiya.
    for o in obs:
        for lat, lon in o.geometry:
            assert 33.30 < lat < 33.39 and 44.33 < lon < 44.40


def test_unmatched_and_speedless_points_are_ignored():
    match = {
        "edges": [{"id": 1, "way_id": 9, "length": 0.1, "speed": 50, "begin_shape_index": 0, "end_shape_index": 1}],
        "matched_points": [{"type": "unmatched"}, {"type": "matched", "edge_index": 0}, {"type": "matched", "edge_index": 0}],
        "shape": _encode([(33.30, 44.40), (33.31, 44.41)]),
    }
    pts = [ProbePoint(0, 0, 0, 10, 5), ProbePoint(5, 0, 0, None, 5), ProbePoint(10, 0, 0, 5, 5)]
    [o] = observations(match, pts)
    assert o.samples == 1 and o.observed_kph == pytest.approx(18)


def _encode(coords, precision=6):
    """Polyline encoder, the inverse of geo.decode_polyline, for building test shapes."""
    out, prev = [], (0, 0)
    for lat, lon in coords:
        cur = (round(lat * 10 ** precision), round(lon * 10 ** precision))
        for delta in (cur[0] - prev[0], cur[1] - prev[1]):
            v = ~(delta << 1) if delta < 0 else delta << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        prev = cur
    return "".join(out)


def _obs(kph, valhalla=50.0, edge=1):
    return EdgeObservation(edge, 9, 100, valhalla, kph, 3, [(33.3, 44.4), (33.31, 44.41)])


def test_segment_needs_two_trips_before_it_is_live():
    now = 1_000_000.0
    state = blend(None, _obs(10), "trip-a", now, night=False)
    assert not is_live(state, now)
    state = blend(state, _obs(10), "trip-a", now + 10, night=False)
    assert not is_live(state, now + 10), "the same trip twice is still one car"
    state = blend(state, _obs(10), "trip-b", now + 20, night=False)
    assert state.trips == MIN_TRIPS and is_live(state, now + 20)


def test_live_speed_follows_recent_observations():
    now = 1_000_000.0
    state = blend(None, _obs(10), "a", now, night=False)
    state = blend(state, _obs(50), "b", now + 600, night=False)  # ten minutes later: mostly the new value
    assert 40 < state.speed_kph < 50
    stale = blend(state, _obs(20), "c", now + 600 + 3600, night=False)  # an hour later: start over
    assert stale.speed_kph == 20 and stale.trips == 1


def test_freeflow_learns_from_faster_and_night_traffic():
    now = 1_000_000.0
    state = blend(None, _obs(80, valhalla=50), "a", now, night=False)
    assert state.freeflow_kph > 50
    state = EdgeState(speed_kph=30, freeflow_kph=60, trips=2, last_trip="a", updated_at=now)
    state = blend(state, _obs(30), "b", now + 5, night=True)
    assert state.freeflow_kph < 60


@pytest.mark.parametrize("speed, freeflow, level", [(45, 50, 0), (30, 50, 1), (20, 50, 2), (5, 50, 3), (5, 0, 0)])
def test_congestion_levels(speed, freeflow, level):
    assert congestion_level(speed, freeflow) == level


def test_route_delay_counts_only_live_edges():
    now = 1_000_000.0
    edges = [RouteEdge(1, 1000, 60), RouteEdge(2, 1000, 60)]
    live = {1: EdgeState(speed_kph=20, freeflow_kph=60, trips=3, last_trip="x", updated_at=now - 60)}
    delay, coverage = route_delay_s(edges, live, now)
    assert delay == pytest.approx(1000 / (20 / 3.6) - 1000 / (60 / 3.6))  # 120 s
    assert coverage == pytest.approx(0.5)
    assert route_delay_s(edges, {}, now) == (0.0, 0.0)


def test_split_trip_on_gaps_and_drops_short_pieces():
    pts = [ProbePoint(t, 0, 0, 1, 5) for t in [0, 5, 10, 15, 200, 205]]
    chunks = split_trip(pts)
    assert [len(c) for c in chunks] == [4]
