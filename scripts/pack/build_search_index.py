"""Builds Daldal's offline search index (SQLite FTS5) from an OpenStreetMap extract.

Usage: python3 build_search_index.py iraq.osm.pbf search.sqlite
Requires: pip install osmium
"""
import sqlite3
import sys
import unicodedata

import osmium

# Tags that make something worth finding by name. Mirrors PlaceCategory in the app.
KEYS = ("amenity", "shop", "tourism", "historic", "place", "highway", "leisure",
        "office", "healthcare", "building", "railway", "aeroway")
SKIP_HIGHWAY = {"bus_stop", "crossing", "traffic_signals", "street_lamp", "stop", "give_way"}


# Must match ArabicSearchNormalizer in the app (Daldal/Offline/OfflineSearchService.swift).
FOLD = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي", "ـ": None})


def normalize(text):
    """Strips harakat and accents, unifies alef/yaa/taa-marbuta forms, lowercases."""
    text = "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")
    return text.translate(FOLD).lower()


def category(tags):
    for key in KEYS:
        if key in tags:
            return key, tags[key]
    return None, None


class Collector(osmium.SimpleHandler):
    def __init__(self, db):
        super().__init__()
        self.db = db
        self.rows = []
        self.seen_streets = set()

    def add(self, kind, osm_id, tags, lat, lon):
        name = tags.get("name")
        if not name:
            return
        key, value = category(tags)
        if key is None or (key == "highway" and value in SKIP_HIGHWAY):
            return
        if key == "highway":
            # A street is split into many ways; keep one entry per name per ~1 km cell.
            cell = (name, round(lat, 2), round(lon, 2))
            if cell in self.seen_streets:
                return
            self.seen_streets.add(cell)
        subtitle = "، ".join(x for x in (tags.get("addr:street"), tags.get("addr:city")) if x)
        name_ar, name_en = tags.get("name:ar", ""), tags.get("name:en", "")
        terms = normalize(" ".join(dict.fromkeys(x for x in (name, name_ar, name_en) if x)))
        self.rows.append((
            f"osm:{kind}{osm_id}", name, name_ar, name_en, subtitle, lat, lon, key, value, terms,
        ))
        if len(self.rows) >= 5000:
            self.flush()

    def flush(self):
        self.db.executemany("INSERT INTO places VALUES (?,?,?,?,?,?,?,?,?,?)", self.rows)
        self.rows.clear()

    def node(self, n):
        if n.location.valid():
            self.add("N", n.id, n.tags, n.location.lat, n.location.lon)

    def way(self, w):
        # The middle node is close enough to locate a way for search purposes.
        nodes = [nd for nd in w.nodes if nd.location.valid()]
        if nodes:
            mid = nodes[len(nodes) // 2].location
            self.add("W", w.id, w.tags, mid.lat, mid.lon)


def main(pbf, out):
    db = sqlite3.connect(out)
    db.executescript("""
        DROP TABLE IF EXISTS places;
        -- Only `terms` is searched: all names, normalized (see normalize()). The rest is for display.
        CREATE VIRTUAL TABLE places USING fts5(
            id UNINDEXED, name UNINDEXED, name_ar UNINDEXED, name_en UNINDEXED, subtitle UNINDEXED,
            lat UNINDEXED, lon UNINDEXED, osm_key UNINDEXED, osm_value UNINDEXED, terms,
            tokenize = 'unicode61 remove_diacritics 2',
            prefix = '2 3'
        );
    """)
    collector = Collector(db)
    collector.apply_file(pbf, locations=True)
    collector.flush()
    db.execute("INSERT INTO places(places) VALUES('optimize')")
    db.commit()
    count = db.execute("SELECT count(*) FROM places").fetchone()[0]
    db.execute("VACUUM")
    db.close()
    print(f"{count} places indexed")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
