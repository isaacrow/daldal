import json, math, sys
p = sys.argv[1]
sites = json.load(open(p, encoding="utf-8"))
def dist(a, b):
    dlat = math.radians(b["latitude"] - a["latitude"]); dlon = math.radians(b["longitude"] - a["longitude"])
    x = math.sin(dlat/2)**2 + math.cos(math.radians(a["latitude"]))*math.cos(math.radians(b["latitude"]))*math.sin(dlon/2)**2
    return 6371000 * 2 * math.asin(math.sqrt(x))
kept = []
for s in sites:  # World Heritage entries come first, so they win.
    twin = next((k for k in kept if dist(k, s) < 1000 and (k["nameEn"] == s["nameEn"] or dist(k, s) < 50 or not k["nameAr"])), None)
    if twin:
        for f in ("nameAr", "imageURL"):
            twin[f] = twin[f] or s[f]
        continue
    kept.append(s)
json.dump(kept, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(kept), "sites;", [ (k["nameEn"], k["nameAr"]) for k in kept if k["isWorldHeritage"]])
