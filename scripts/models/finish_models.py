"""Finishes a build_models.py run for publishing: a transparent map icon per model (from its 3D preview render) and
each monument's real height from Wikidata (P2048) where it's recorded, so AR shows it at true size.

    D:/daldal-tools/TripoSR/.venv/Scripts/python.exe -X utf8 scripts/models/finish_models.py D:/daldal-tools/models-out
"""
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import rembg
from PIL import Image

UA = {"User-Agent": "Daldal/0.1 (https://github.com/isaacrow/daldal; 3D model builder)"}
DEFAULT_HEIGHT = 20.0  # metres, when Wikidata doesn't say
ICON = 160


def heights(ids):
    """Wikidata heights in metres, where recorded."""
    found = {}
    ids = list(ids)
    for start in range(0, len(ids), 60):
        values = " ".join(f"wd:{i}" for i in ids[start:start + 60])
        query = f"""SELECT ?item ?height WHERE {{ VALUES ?item {{ {values} }}
          ?item p:P2048/psn:P2048/wikibase:quantityAmount ?height. }}"""
        url = "https://query.wikidata.org/sparql?" + urllib.parse.urlencode({"query": query, "format": "json"})
        for attempt in range(3):
            try:
                data = json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60))
                break
            except Exception:
                time.sleep(3 + attempt * 5)
        else:
            continue
        for row in data["results"]["bindings"]:
            qid = row["item"]["value"].rsplit("/", 1)[1]
            metres = float(row["height"]["value"])  # psn: normalised to metres
            if 2 <= metres <= 400:
                found[qid] = max(found.get(qid, 0), metres)
    return found


def main(out_dir):
    out = Path(out_dir)
    catalog = json.load(open(out / "models.json", encoding="utf-8"))
    session = rembg.new_session()
    (out / "icons").mkdir(exist_ok=True)
    for entry in catalog:
        render = out / "review" / f"{entry['id']}-render.png"
        if not render.exists():
            continue
        cut = rembg.remove(Image.open(render).convert("RGB"), session=session)
        box = cut.getbbox()
        if box:
            cut = cut.crop(box)
        cut.thumbnail((ICON, ICON))
        icon = Image.new("RGBA", (ICON, ICON))
        icon.paste(cut, ((ICON - cut.width) // 2, ICON - cut.height))  # Standing on the bottom edge.
        icon.save(out / "icons" / f"{entry['id']}.png", optimize=True)
        entry["icon"] = f"{entry['id']}.png"

    found = heights(e["id"] for e in catalog)
    for entry in catalog:
        entry["height"] = round(found.get(entry["id"], DEFAULT_HEIGHT), 1)
    json.dump(catalog, open(out / "models.json", "w", encoding="utf-8"), indent=1)
    print(len(catalog), "models,", len(found), "with a recorded height,",
          sum(1 for e in catalog if e.get("icon")), "icons")


if __name__ == "__main__":
    main(sys.argv[1])
