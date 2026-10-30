#!/bin/sh
# Rebuilds Daldal/Resources/Data/iraq-heritage.json from Wikidata (CC0).
# Hand-added "modelURL" values are kept.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../../Daldal/Resources/Data/iraq-heritage.json"
tmp=$(mktemp)
curl -sfG "https://query.wikidata.org/sparql" -H "Accept: application/sparql-results+json" \
  -A "Daldal/0.1 (heritage catalogue builder)" --data-urlencode "query@$here/iraq-heritage.rq" -o "$tmp"
python3 -X utf8 "$here/build.py" "$tmp" "$out"
python3 -X utf8 "$here/dedupe.py" "$out"
rm -f "$tmp"
