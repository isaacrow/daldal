"""Writes manifest.json for a built pack: every file with its size and SHA-256.

The app reads this to know what to download, to resume, and to verify each file.
"""
import hashlib
import json
import os
import sys
import time
from urllib.parse import quote

root, base_url = sys.argv[1], sys.argv[2].rstrip("/")
files = []
for folder, _, names in os.walk(root):
    for name in sorted(names):
        path = os.path.join(folder, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel == "manifest.json" or rel.startswith("."):
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
        files.append({"path": rel, "url": f"{base_url}/{quote(rel)}",
                      "bytes": os.path.getsize(path), "sha256": digest.hexdigest()})

manifest = {
    "id": "iraq",
    "version": time.strftime("%Y%m%d"),
    "files": sorted(files, key=lambda f: f["path"]),
}
with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print(f"manifest: {len(files)} files, {sum(f['bytes'] for f in files) / 1e6:.0f} MB")
