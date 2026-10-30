import json, re, sys
src, out = sys.argv[1], sys.argv[2]
rows = json.load(open(src, encoding="utf-8"))["results"]["bindings"]
sites = {}
for r in rows:
    qid = r["item"]["value"].rsplit("/", 1)[1]
    m = re.match(r"Point\(([-\d.]+) ([-\d.]+)\)", r["coord"]["value"])
    if not m: continue
    lon, lat = float(m.group(1)), float(m.group(2))
    if not (28.95 <= lat <= 37.45 and 38.7 <= lon <= 48.8): continue
    s = sites.setdefault(qid, {"id": qid, "latitude": round(lat, 6), "longitude": round(lon, 6),
                               "nameAr": None, "nameEn": None, "imageURL": None, "isWorldHeritage": False})
    s["nameAr"] = s["nameAr"] or r.get("ar", {}).get("value")
    s["nameEn"] = s["nameEn"] or r.get("en", {}).get("value")
    if r.get("image") and not s["imageURL"]:
        s["imageURL"] = r["image"]["value"].replace("http://", "https://") + "?width=800"
    if r.get("wh"): s["isWorldHeritage"] = True
result = [s for s in sites.values() if s["nameAr"] or s["nameEn"]]
# Keep 3D model links that were added by hand to the previous catalogue.
try:
    previous = {p["id"]: p.get("modelURL") for p in json.load(open(out, encoding="utf-8"))}
except (OSError, ValueError):
    previous = {}
for site in result:
    if previous.get(site["id"]):
        site["modelURL"] = previous[site["id"]]
result.sort(key=lambda s: (not s["isWorldHeritage"], s["nameEn"] or ""))
json.dump(result, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(result), "sites")
for s in result: print(("WH " if s["isWorldHeritage"] else "   ") + f'{s["nameEn"]} | {s["nameAr"]} | {s["latitude"]},{s["longitude"]}')
