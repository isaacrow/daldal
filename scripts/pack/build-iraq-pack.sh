#!/bin/sh
# Builds the offline Iraq pack that Daldal downloads: map tiles, routing graph, search index, fonts.
# Needs Docker, curl, python3 (with `pip install osmium`), and ~6 GB of free disk.
#
#   scripts/pack/build-iraq-pack.sh [output-dir] [base-url]
#
# Upload the output directory as-is to your CDN, and set PackConfig.manifestURL to <base-url>/manifest.json.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "${1:-build/iraq-pack}" && cd "${1:-build/iraq-pack}" && pwd)
base_url="${2:-https://cdn.example.com/packs/iraq}"
work="$out/.work"
mkdir -p "$work"

# Keep the routing tile format in step with the valhalla-mobile version in project.yml (Valhalla 3.9.x).
VALHALLA_IMAGE="${VALHALLA_IMAGE:-ghcr.io/valhalla/valhalla:3.9.0}"
PLANETILER_IMAGE="${PLANETILER_IMAGE:-ghcr.io/onthegomap/planetiler:latest}"

echo "==> 1/5 OpenStreetMap extract for Iraq (Geofabrik, ODbL)"
curl -fL -o "$work/iraq.osm.pbf" https://download.geofabrik.de/asia/iraq-latest.osm.pbf

echo "==> 2/5 Vector map tiles (OpenMapTiles schema, same as the online style)"
docker run --rm -v "$work":/data "$PLANETILER_IMAGE" \
  --osm-path=/data/iraq.osm.pbf --download --output=/data/iraq.pmtiles --force
mv "$work/iraq.pmtiles" "$out/iraq.pmtiles"

echo "==> 3/5 Valhalla routing graph"
docker run --rm -v "$work":/data -w /data "$VALHALLA_IMAGE" sh -c '
  set -e
  mkdir -p valhalla_tiles
  valhalla_build_config --mjolnir-tile-dir /data/valhalla_tiles \
    --mjolnir-tile-extract /data/valhalla_tiles.tar \
    --mjolnir-timezone /data/valhalla_tiles/timezones.sqlite \
    --mjolnir-admin /data/valhalla_tiles/admins.sqlite > valhalla.json
  valhalla_build_timezones > valhalla_tiles/timezones.sqlite
  valhalla_build_admins -c valhalla.json iraq.osm.pbf
  valhalla_build_tiles -c valhalla.json iraq.osm.pbf
  valhalla_build_extract -c valhalla.json -v'
mv "$work/valhalla_tiles.tar" "$out/routing.tar"

echo "==> 4/5 Offline search index"
python3 -X utf8 "$here/build_search_index.py" "$work/iraq.osm.pbf" "$out/search.sqlite"

echo "==> 5/5 Map fonts (Latin + Arabic ranges)"
# Saved without spaces ("NotoSansBold") so the app can point MapLibre at plain file:// URLs.
for weight in Regular Bold Italic; do
  mkdir -p "$out/fonts/NotoSans$weight"
  for range in 0-255 256-511 1536-1791 1792-2047 64256-64511 64512-64767 64768-65023 65024-65279; do
    curl -fsS -o "$out/fonts/NotoSans$weight/$range.pbf"       "https://tiles.openfreemap.org/fonts/Noto%20Sans%20$weight/$range.pbf"
  done
done

python3 -X utf8 "$here/write_manifest.py" "$out" "$base_url"
rm -rf "$work"
echo "Done: $out"
