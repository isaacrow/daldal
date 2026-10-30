"""Driver reports: what counts as the same report, how long reports live, and how votes end them."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from .geo import haversine_m, heading_difference

# Lifetime of a fresh report, in minutes. "Still there" votes extend it.
LIFETIME_MIN = {
    "jam": 30,
    "accident": 90,
    "police": 60,
    "hazard": 180,
    "flood": 360,    # Baghdad streets can stay flooded for hours after heavy rain.
    "closure": 720,
    "pothole": 7 * 24 * 60,   # Potholes stay until someone confirms they're fixed.
    "roadwork": 3 * 24 * 60,
    "brokenLight": 24 * 60,
}
TYPES = frozenset(LIFETIME_MIN)
# Reports about one side of the road: a jam heading north says nothing about southbound traffic.
DIRECTIONAL = frozenset({"jam", "accident", "police", "hazard", "pothole"})

DUPLICATE_RADIUS_M = 150
DUPLICATE_WINDOW = timedelta(minutes=30)
# Closures change routing for everyone, so they need a second, independent driver first.
CLOSURE_CONFIRMATIONS = 2


@dataclass
class Report:
    id: str
    type: str
    lat: float
    lon: float
    heading: float | None
    reporter: str
    up: int
    down: int
    created_at: datetime
    expires_at: datetime


def expiry(type_: str, now: datetime) -> datetime:
    return now + timedelta(minutes=LIFETIME_MIN[type_])


def is_duplicate(existing: Report, type_: str, lat: float, lon: float, heading: float | None, now: datetime) -> bool:
    """A new report of the same thing nearby counts as a confirmation, not a second pin."""
    if existing.type != type_ or now - existing.created_at > DUPLICATE_WINDOW or existing.expires_at <= now:
        return False
    if haversine_m((existing.lat, existing.lon), (lat, lon)) > DUPLICATE_RADIUS_M:
        return False
    if type_ in DIRECTIONAL and existing.heading is not None and heading is not None:
        return heading_difference(existing.heading, heading) <= 60
    return True


def apply_vote(report: Report, still_there: bool, now: datetime) -> bool:
    """Updates the report for one vote. Returns True if the report should be removed."""
    if still_there:
        report.up += 1
        # Confirmed now: keep it for at least half its normal lifetime from this moment.
        report.expires_at = max(report.expires_at, now + timedelta(minutes=LIFETIME_MIN[report.type] / 2))
        return False
    report.down += 1
    # The reporter's own report counts as one "up". Two drivers saying "gone" outweigh a lone reporter.
    return report.down >= max(2, report.up)


def reporter_trust(confirmed: int, rejected: int) -> float:
    """Laplace-smoothed share of a reporter's reports that others confirmed. New reporters start at 0.5."""
    return (confirmed + 1) / (confirmed + rejected + 2)


def visible(report: Report, trust: float, now: datetime) -> bool:
    """Reports from reporters with a poor record stay hidden until someone else confirms them."""
    if report.expires_at <= now:
        return False
    return trust >= 0.3 or report.up >= 2


def affects_routing(report: Report, now: datetime) -> bool:
    return report.type == "closure" and report.up >= CLOSURE_CONFIRMATIONS and report.expires_at > now
