"""Builds Daldal's city guides: the best places to visit in each city, with spoken descriptions.

For each city in the maps repo's cities.json, asks Wikidata (CC0) for notable places inside the city's area
(mosques, shrines, museums, archaeological sites, palaces, markets, parks, bridges, monuments), ranks them by
how many Wikipedia languages cover them, and adds each one's Arabic and English Wikipedia summary
(CC BY-SA 4.0; the app credits and links every article).

    python3 -X utf8 scripts/guide/build_guides.py <cities.json> Daldal/Resources/Data/city-guides.json
"""
import json
import re
import sys
import time
import urllib.parse
import urllib.request

UA = {"User-Agent": "Daldal/0.1 (https://github.com/isaacrow/daldal; city guide builder)"}
PER_CITY = 20

# What counts as a place to visit.
CLASSES = {
    "Q32815": "mosque", "Q697295": "shrine", "Q162875": "shrine", "Q381885": "shrine",
    "Q33506": "museum", "Q207694": "museum",
    "Q839954": "archaeological", "Q15661340": "archaeological",
    "Q16560": "palace", "Q23413": "castle", "Q57821": "castle",
    "Q37654": "market", "Q1149652": "market",
    "Q22698": "park", "Q43501": "park",
    "Q12280": "bridge", "Q4989906": "monument", "Q570116": "attraction",
    "Q16970": "church", "Q2977": "church", "Q44613": "church",
}


def get(url):
    req = urllib.request.Request(url, headers=UA)
    for attempt in range(4):
        try:
            return json.load(urllib.request.urlopen(req, timeout=60))
        except Exception:
            time.sleep(2 + attempt * 3)
    return None


def places_in(bbox):
    min_lon, min_lat, max_lon, max_lat = bbox
    classes = " ".join(f"wd:{c}" for c in CLASSES)
    query = f"""
SELECT ?item ?class ?coord ?ar ?en ?image ?links ?arTitle ?enTitle WHERE {{
  SERVICE wikibase:box {{
    ?item wdt:P625 ?coord.
    bd:serviceParam wikibase:cornerSouthWest "Point({min_lon} {min_lat})"^^geo:wktLiteral.
    bd:serviceParam wikibase:cornerNorthEast "Point({max_lon} {max_lat})"^^geo:wktLiteral.
  }}
  VALUES ?class {{ {classes} }}
  ?item wdt:P31 ?class; wikibase:sitelinks ?links.
  FILTER(?links >= 2)
  OPTIONAL {{ ?item rdfs:label ?ar FILTER(lang(?ar) = "ar") }}
  OPTIONAL {{ ?item rdfs:label ?en FILTER(lang(?en) = "en") }}
  OPTIONAL {{ ?item wdt:P18 ?image }}
  OPTIONAL {{ ?arArticle schema:about ?item; schema:isPartOf <https://ar.wikipedia.org/>; schema:name ?arTitle }}
  OPTIONAL {{ ?enArticle schema:about ?item; schema:isPartOf <https://en.wikipedia.org/>; schema:name ?enTitle }}
}}"""
    data = get("https://query.wikidata.org/sparql?" + urllib.parse.urlencode({"query": query, "format": "json"}))
    found = {}
    for r in (data or {}).get("results", {}).get("bindings", []):
        qid = r["item"]["value"].rsplit("/", 1)[1]
        m = re.match(r"Point\(([-\d.]+) ([-\d.]+)\)", r["coord"]["value"])
        if not m:
            continue
        p = found.setdefault(qid, {
            "id": qid, "lat": round(float(m.group(2)), 6), "lon": round(float(m.group(1)), 6),
            "kind": CLASSES.get(r["class"]["value"].rsplit("/", 1)[1], "attraction"),
            "links": int(r["links"]["value"]),
        })
        for key, field in (("ar", "name_ar"), ("en", "name_en"), ("arTitle", "wiki_ar"), ("enTitle", "wiki_en")):
            if key in r and not p.get(field):
                p[field] = r[key]["value"]
        if "image" in r and not p.get("image"):
            p["image"] = r["image"]["value"].replace("http://", "https://") + "?width=800"
    ranked = sorted((p for p in found.values() if p.get("name_ar") or p.get("name_en")), key=lambda p: -p["links"])
    return ranked[:PER_CITY]


def summary(lang, title):
    if not title:
        return None
    data = get(f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_")))
    text = (data or {}).get("extract", "").strip()
    if not text:
        return None
    # Spoken aloud: keep it to a few sentences.
    if len(text) > 700:
        cut = max(text.rfind(".", 0, 700), text.rfind("۔", 0, 700), text.rfind("،", 0, 700))
        text = text[: cut + 1 if cut > 200 else 700]
    return text


def main(cities_path, out_path):
    cities = json.load(open(cities_path, encoding="utf-8"))
    guides = []
    for city in cities:
        places = places_in(city["bbox"])
        for p in places:
            p["summary_ar"] = summary("ar", p.get("wiki_ar"))
            p["summary_en"] = summary("en", p.get("wiki_en"))
            p.pop("links", None)
            time.sleep(0.2)
        guides.append({"id": city["id"], "name_ar": city["name_ar"], "name_en": city["name_en"],
                       "center": city["center"], "places": places})
        print(f"{city['id']:13} {len(places):2} places  " + ", ".join((p.get("name_en") or p.get("name_ar"))[:28] for p in places[:4]))
        time.sleep(1)
    json.dump(guides, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(sum(len(c["places"]) for c in guides), "places in", len(guides), "cities")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
