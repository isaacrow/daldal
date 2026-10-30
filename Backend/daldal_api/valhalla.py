"""Thin async client for the Valhalla server (same Iraq graph as the app's offline pack)."""
from __future__ import annotations

import hashlib
from collections import OrderedDict

import httpx

from .geo import decode_polyline
from .traffic import ProbePoint, RouteEdge, trace_request


class Valhalla:
    def __init__(self, base_url: str, client: httpx.AsyncClient | None = None):
        self.base_url = base_url
        self.client = client or httpx.AsyncClient(timeout=20)
        # Route shapes repeat a lot (everyone heading to the same places); matching is the costly part.
        self._route_cache: OrderedDict[str, list[RouteEdge]] = OrderedDict()

    async def match_trace(self, points: list[ProbePoint]) -> dict:
        response = await self.client.post(f"{self.base_url}/trace_attributes", json=trace_request(points))
        response.raise_for_status()
        return response.json()

    async def route_edges(self, polyline6: str) -> list[RouteEdge]:
        """The graph edges a route runs along. Route shapes sit exactly on the graph, so edge_walk is exact."""
        key = hashlib.sha1(polyline6.encode()).hexdigest()
        if key in self._route_cache:
            self._route_cache.move_to_end(key)
            return self._route_cache[key]

        shape = [{"lat": lat, "lon": lon} for lat, lon in decode_polyline(polyline6)]
        response = await self.client.post(f"{self.base_url}/trace_attributes", json={
            "shape": shape,
            "costing": "auto",
            "shape_match": "edge_walk",
            "filters": {"attributes": ["edge.id", "edge.length", "edge.speed"], "action": "include"},
        })
        response.raise_for_status()
        edges = [
            RouteEdge(edge_id=int(e["id"]), length_m=float(e["length"]) * 1000, valhalla_kph=float(e["speed"]))
            for e in response.json().get("edges", []) if "id" in e and "length" in e and "speed" in e
        ]
        self._route_cache[key] = edges
        if len(self._route_cache) > 2000:
            self._route_cache.popitem(last=False)
        return edges
