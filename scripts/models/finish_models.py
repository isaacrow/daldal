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
# Reviewed by eye (review/*-render.png): the place's photo is a map, a crowd, a flat landscape, an aerial view or a
# museum object rather than the building, so the model would mislead. Leave them out.
REJECTED = {
    "Q1000577", "Q100329356", "Q10424690", "Q1136681", "Q132272", "Q133132919", "Q1372270", "Q1744863", "Q206236",
    "Q2302612", "Q237614", "Q244746", "Q253208", "Q25933006", "Q28716288", "Q310799", "Q3818869", "Q346445",
    "Q375685", "Q392725", "Q501259", "Q5680", "Q584605", "Q607583", "Q619707", "Q740952", "Q853946", "Q909799",
    "Q98917963", "Q107423789", "Q1079803", "Q1193666", "Q19414891", "Q3462642", "Q5687554", "Q65151623", "Q672905",
    "Q7697547",
}
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
    catalog = [e for e in json.load(open(out / "models.json", encoding="utf-8")) if e["id"] not in REJECTED]
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
