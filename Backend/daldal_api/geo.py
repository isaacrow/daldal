"""Small geographic helpers. Coordinates are (lat, lon) tuples unless a name says otherwise."""
import math

EARTH_RADIUS_M = 6_371_000.0

# Iraq with a small margin; must match Region.swift in the app.
IRAQ_BBOX = (38.70, 28.95, 48.80, 37.45)  # min_lon, min_lat, max_lon, max_lat


def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat, dlon = lat2 - lat1, math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(h))


def in_iraq(lat: float, lon: float) -> bool:
    min_lon, min_lat, max_lon, max_lat = IRAQ_BBOX
    return min_lat <= lat <= max_lat and min_lon <= lon <= max_lon


def parse_bbox(text: str, max_area_deg2: float = 1.0) -> tuple[float, float, float, float]:
    """Parses "min_lon,min_lat,max_lon,max_lat". Rejects inverted or oversized boxes."""
    parts = [float(x) for x in text.split(",")]
    if len(parts) != 4:
        raise ValueError("bbox needs four numbers")
    min_lon, min_lat, max_lon, max_lat = parts
    if not (min_lon < max_lon and min_lat < max_lat):
        raise ValueError("bbox is inverted")
    if (max_lon - min_lon) * (max_lat - min_lat) > max_area_deg2:
        raise ValueError("bbox is too large; zoom in")
    return min_lon, min_lat, max_lon, max_lat


def decode_polyline(encoded: str, precision: int = 6) -> list[tuple[float, float]]:
    """Decodes a Google-style encoded polyline (Valhalla uses precision 6)."""
    coords, index, lat, lon, factor = [], 0, 0, 0, 10 ** precision
    while index < len(encoded):
        for axis in (0, 1):
            shift = result = 0
            while True:
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if axis == 0:
                lat += delta
            else:
                lon += delta
        coords.append((lat / factor, lon / factor))
    return coords


def square_around(lat: float, lon: float, half_size_m: float) -> list[list[float]]:
    """A closed square ring in [lon, lat] order, as Valhalla's exclude_polygons expects."""
    dlat = half_size_m / 111_320.0
    dlon = half_size_m / (111_320.0 * max(math.cos(math.radians(lat)), 0.01))
    ring = [
        [lon - dlon, lat - dlat], [lon + dlon, lat - dlat],
        [lon + dlon, lat + dlat], [lon - dlon, lat + dlat],
    ]
    return ring + [ring[0]]


def heading_difference(a: float, b: float) -> float:
    """Smallest angle between two compass headings, 0..180."""
    d = abs(a - b) % 360
    return 360 - d if d > 180 else d
