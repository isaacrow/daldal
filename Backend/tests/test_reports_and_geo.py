import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from daldal_api import reports as r
from daldal_api.geo import decode_polyline, haversine_m, heading_difference, parse_bbox, square_around

NOW = datetime(2026, 10, 30, 18, 0, tzinfo=timezone.utc)
TAHRIR = (33.3128, 44.3915)


def report(type_="accident", lat=TAHRIR[0], lon=TAHRIR[1], heading=90.0, up=1, down=0, age_min=5):
    created = NOW - timedelta(minutes=age_min)
    return r.Report("id", type_, lat, lon, heading, "reporter", up, down, created, r.expiry(type_, created))


def test_same_thing_nearby_is_a_duplicate():
    assert r.is_duplicate(report(), "accident", 33.3135, 44.3915, 100, NOW)  # ~80 m away


@pytest.mark.parametrize("kwargs, why", [
    ({"type_": "police"}, "different type"),
    ({"lat": 33.3160}, "350 m away"),
    ({"heading": 270.0}, "opposite side of the road"),
    ({"age_min": 45}, "too old to merge"),
])
def test_not_duplicates(kwargs, why):
    existing = report(**kwargs)
    assert not r.is_duplicate(existing, "accident", TAHRIR[0], TAHRIR[1], 90, NOW), why


def test_floods_ignore_heading():
    assert r.is_duplicate(report("flood", heading=0), "flood", TAHRIR[0], TAHRIR[1], 180, NOW)


def test_votes_extend_or_remove():
    rep = report("police", age_min=50)  # 10 minutes left
    assert not r.apply_vote(rep, True, NOW)
    assert rep.up == 2 and rep.expires_at >= NOW + timedelta(minutes=30)

    lone = report()
    assert not r.apply_vote(lone, False, NOW), "one 'gone' vote doesn't remove a report"
    assert r.apply_vote(lone, False, NOW), "two do"

    confirmed = report(up=3)  # Three drivers saw it: it takes three "gone" votes to remove.
    assert not r.apply_vote(confirmed, False, NOW)
    assert not r.apply_vote(confirmed, False, NOW)
    assert r.apply_vote(confirmed, False, NOW)


def test_trust_and_visibility():
    assert r.reporter_trust(0, 0) == 0.5
    assert r.reporter_trust(0, 8) == pytest.approx(0.1)
    assert r.visible(report(), 0.5, NOW)
    assert not r.visible(report(), 0.1, NOW), "untrusted reporters need a confirmation"
    assert r.visible(report(up=2), 0.1, NOW)
    assert not r.visible(report(age_min=200), 0.9, NOW), "expired"


def test_closures_need_two_drivers_to_change_routes():
    assert not r.affects_routing(report("closure"), NOW)
    assert r.affects_routing(report("closure", up=2), NOW)
    assert not r.affects_routing(report("accident", up=5), NOW)


def test_decode_real_route_geometry():
    fixture = Path(__file__).parents[2] / "DaldalTests" / "Fixtures" / "valhalla-baghdad-osrm.json"
    route = json.loads(fixture.read_text(encoding="utf-8"))["routes"][0]
    coords = decode_polyline(route["geometry"])
    assert haversine_m(coords[0], TAHRIR) < 150, "starts at Tahrir Square"
    length = sum(haversine_m(a, b) for a, b in zip(coords, coords[1:]))
    assert length == pytest.approx(route["distance"], rel=0.01)


def test_bbox_and_shapes():
    assert parse_bbox("44.3,33.2,44.5,33.4") == (44.3, 33.2, 44.5, 33.4)
    for bad in ["1,2,3", "44.5,33.2,44.3,33.4", "38,29,48,37"]:
        with pytest.raises(ValueError):
            parse_bbox(bad)
    ring = square_around(*TAHRIR, 20)
    assert ring[0] == ring[-1] and len(ring) == 5
    assert haversine_m((ring[0][1], ring[0][0]), (ring[1][1], ring[1][0])) == pytest.approx(40, rel=0.02)
    assert heading_difference(350, 10) == 20
