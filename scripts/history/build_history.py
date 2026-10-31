"""Builds Daldal's history layer: battles, sieges and other key events that happened in Iraq, for Heritage Scan.

Wikidata (CC0) gives each event's place and date; the Arabic and English Wikipedia summaries are CC BY-SA 4.0,
and the app credits and links every article. Heritage Scan shows the events within a few kilometres of the
monument or old city the visitor is standing in.

    python3 -X utf8 scripts/history/build_history.py Daldal/Resources/Data/history-events.json
"""
import json
import re
import sys
import time
import urllib.parse
import urllib.request

UA = {"User-Agent": "Daldal/0.1 (https://github.com/isaacrow/daldal; history builder)"}
# Iraq's bounding box (lon/lat), a little generous at the borders.
BOX = (38.7, 29.0, 48.8, 37.4)
KINDS = {
    "Q178561": "battle", "Q188055": "siege", "Q1261499": "battle",  # battle, siege, naval battle
    "Q124734": "uprising", "Q3199915": "massacre", "Q2001676": "battle",  # uprising, massacre, offensive
    "Q645883": "battle", "Q831663": "battle",  # military operation, military campaign
    "Q1190554": "event",  # occurrence: founding, treaties, ... (only well-covered ones survive the filter)
}
LIMIT = 600
CUTOFF_YEAR = 1950


def get(url):
    req = urllib.request.Request(url, headers=UA)
    for attempt in range(4):
        try:
            return json.load(urllib.request.urlopen(req, timeout=90))
        except Exception:
            time.sleep(2 + attempt * 3)
    return None


def events():
    min_lon, min_lat, max_lon, max_lat = BOX
    kinds = " ".join(f"wd:{k}" for k in KINDS)
    query = f"""
SELECT ?item ?kind ?coord ?date ?start ?ar ?en ?links ?arTitle ?enTitle WHERE {{
  SERVICE wikibase:box {{
    ?item wdt:P625 ?coord.
    bd:serviceParam wikibase:cornerSouthWest "Point({min_lon} {min_lat})"^^geo:wktLiteral.
    bd:serviceParam wikibase:cornerNorthEast "Point({max_lon} {max_lat})"^^geo:wktLiteral.
  }}
  VALUES ?kind {{ {kinds} }}
  ?item wdt:P31 ?kind; wikibase:sitelinks ?links.
  FILTER(?links >= 2)
  OPTIONAL {{ ?item wdt:P585 ?date }}
  OPTIONAL {{ ?item wdt:P580 ?start }}
  OPTIONAL {{ ?item rdfs:label ?ar FILTER(lang(?ar) = "ar") }}
  OPTIONAL {{ ?item rdfs:label ?en FILTER(lang(?en) = "en") }}
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
        e = found.setdefault(qid, {
            "id": qid, "lat": round(float(m.group(2)), 5), "lon": round(float(m.group(1)), 5),
            "kind": KINDS.get(r["kind"]["value"].rsplit("/", 1)[1], "event"),
            "links": int(r["links"]["value"]),
        })
        for key in ("date", "start"):
            if key in r and "year" not in e:
                y = re.match(r"(-?\d+)-", r[key]["value"])
                if y:
                    e["year"] = int(y.group(1))
        for key, field in (("ar", "name_ar"), ("en", "name_en"), ("arTitle", "wiki_ar"), ("enTitle", "wiki_en")):
            if key in r and not e.get(field):
                e[field] = r[key]["value"]
    # Generic "occurrences" are only kept when widely covered; battles and sieges need less.
    keep = [e for e in found.values()
            if (e.get("wiki_ar") or e.get("wiki_en")) and (e["kind"] != "event" or e["links"] >= 12)]
    return sorted(keep, key=lambda e: -e["links"])[:LIMIT]


def summary(lang, title):
    if not title:
        return None
    data = get(f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_")))
    text = (data or {}).get("extract", "").strip()
    if not text:
        return None
    # Read aloud on a card: two or three sentences.
    if len(text) > 420:
        cut = max(text.rfind(".", 0, 420), text.rfind("۔", 0, 420), text.rfind("،", 0, 420))
        text = text[: cut + 1 if cut > 150 else 420]
    return text


def main(out_path):
    found = events()
    for i, e in enumerate(found):
        e["summary_ar"] = summary("ar", e.get("wiki_ar"))
        e["summary_en"] = summary("en", e.get("wiki_en"))
        e.pop("links", None)
        if i % 20 == 0:
            print(i, e.get("name_en") or e.get("name_ar"), e.get("year"))
        time.sleep(0.15)
    # Heritage, not news: recent wars are still raw for many visitors.
    found = [e for e in found if e.get("year") is not None and e["year"] < CUTOFF_YEAR]
    found.sort(key=lambda e: e["year"])
    json.dump(found, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(len(found), "events")


if __name__ == "__main__":
    main(sys.argv[1])
