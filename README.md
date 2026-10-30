# دلدل — Daldal

A navigation app for Iraq. It uses an open 3D map (no Google or Apple maps), Liquid Glass, and geographic AR at heritage sites.

Status: **Phase 3** — live traffic from anonymous drivers, driver reports, live ETAs, faster-route switching and closure avoidance, on top of Phase 2 (offline map, routing, Drive Mode, Arabic voice) and Phase 1 (3D map, search, heritage, geographic AR). See [PLAN.md](PLAN.md).

## Build (needs a Mac)

You need Xcode 26 or later and an iPhone running iOS 26. AR needs a real device; the Simulator can't run it.

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Daldal.xcodeproj
```

Set your team in **Signing & Capabilities** (or `DEVELOPMENT_TEAM` in `project.yml`), then run.
The project file is generated from `project.yml`, so edit that file instead of the `.xcodeproj`.

## What's in Phase 1

| Area | Files |
|---|---|
| 3D map (MapLibre, OpenStreetMap tiles, extruded buildings, day/night) | `Daldal/Map/` |
| Search limited to Iraq, home/work, recents | `Daldal/Search/` |
| 41 Iraqi heritage sites from Wikidata, map layer, "you're at…" banner | `Daldal/Heritage/`, `Resources/Data/iraq-heritage.json` |
| Geographic AR (GPS + compass anchoring, LiDAR occlusion, USDZ models) | `Daldal/AR/` |
| Liquid Glass controls, SVG icon set, Arabic-first strings | `Daldal/DesignSystem/`, `Resources/` |
| City maps: download each city (map, routing, search), verified; works offline | `Daldal/Offline/`, [daldal-maps](https://github.com/isaacrow/daldal-maps) |
| Satellite view (EOX Sentinel-2 2016, CC BY 4.0) and terrain shading (AWS Terrain Tiles) | `Daldal/Map/MapStyle.swift` |
| Walking AR navigation: chevrons on the ground, turn arrows, voice | `Daldal/AR/WalkAR*.swift` |
| Drive Scan: on-device detection of vehicles, people, lights, signs; 3D road view; collision warning | `Daldal/Scan/` |
| Routing: on-device Valhalla with online fallback, through Ferrostar | `Daldal/Routing/` |
| Drive Mode: maneuver banner, lanes, speed and limit, ETA, rerouting | `Daldal/Navigation/` |
| Arabic/English voice written by Daldal, speed-based timing, chime, music ducking | `Daldal/Voice/` |
| Live traffic, reports, "still there?", faster routes, closures (app side) | `Daldal/Live/`, `Daldal/Navigation/DriveAlerts.swift` |
| Live server: probes → map matching → traffic, reports, live ETA, closures | `Backend/` |

## Rules

- **No emoji anywhere.** Icons are SVGs in `Assets.xcassets/Icons`, one per `DaldalIcon` case. `scripts/check-no-emoji.sh` runs on every build and fails it if an emoji appears.
- **Only open data we're allowed to ship.** OpenStreetMap (ODbL, attribution stays visible on the map), Wikidata (CC0), and Wikimedia Commons images (credited per file). No scraping of Google Maps or Waze.
- **AR is for walking.** The AR views pause above walking speed.
- **Bundled third-party data:** Noto Sans glyphs (SIL OFL), YOLOv3 (Int8) Core ML model (darknet, public domain;
  see `Daldal/Resources/Models/YOLOv3-NOTICE.txt`).

## Adding a 3D model to a heritage site

1. Get a USDZ authored in metres, with the origin at ground level. Sources: Apple **Object Capture** (Reality Composer on iPhone), or a Sketchfab/Smithsonian model whose licence allows app use. Check every licence and record it.
2. Host the USDZ on our CDN.
3. Add `"modelURL": "https://…/babylon.usdz"` to the site in `Daldal/Resources/Data/iraq-heritage.json`.

The app downloads the model once, caches it, and shows it in place of the light-column marker.

## Regenerating the heritage catalogue

The catalogue comes from a Wikidata SPARQL query run by the scripts in `scripts/heritage/`. Re-run it to pick up new sites. Wikidata is CC0, so the result can be bundled freely.

## City maps

Each city's offline files are built every Monday by GitHub Actions in the public
[daldal-maps](https://github.com/isaacrow/daldal-maps) repo, and the app downloads them from its latest release
(`CityMapsConfig.catalogURL`). To add a city, add it to `cities.json` there.

## Building a single all-Iraq pack (older approach)

The script below builds one pack for the whole country. The app now uses per-city maps instead; keep this for
a self-hosted CDN. Run it on any Linux or Mac machine with Docker (about an hour, ~6 GB of disk):

```bash
pip install osmium
```

```bash
scripts/pack/build-iraq-pack.sh build/iraq-pack https://YOUR-CDN/packs/iraq
```

Upload `build/iraq-pack/` to that URL, then set `PackConfig.manifestURL` in `Daldal/Offline/OfflinePack.swift`.
The pack holds:
- `iraq.pmtiles`: the map
- `routing.tar`: the Valhalla graph
- `search.sqlite`: the search index
- `fonts/`
- `manifest.json`: every file's size and SHA-256

The routing graph must be built with the same Valhalla version as the `valhalla-mobile` package (3.9).

## Check first on a real device

These depend on library behaviour that can't be tested without building:
1. The offline map loads from `pmtiles://file://…`. A MapLibre issue reported URL parsing trouble on iOS 17. If tiles don't appear, switch the pack to `.mbtiles`.
2. Offline routing opens `routing.tar` and returns the same route as online for the same trip.
3. A background pack download finishes with the app closed.
4. The speed-limit sign appears. It depends on Valhalla returning speed annotations; when it doesn't, the panel shows only your speed.

## Live server (Backend/)

Python (FastAPI), PostgreSQL/PostGIS, and a Valhalla server for the same Iraq graph. It is split into two processes:
- The **API** stores incoming GPS points briefly, and serves traffic, reports, ETAs and closures.
- The **worker** map-matches the stored points with Valhalla, updates per-road speeds, and deletes the raw points.

```bash
cd Backend
```

```bash
docker compose up
```

The first start builds the Iraq routing graph (20–40 minutes). Then set `LiveConfig.baseURL` in `Daldal/Live/LiveAPI.swift`. Until it is set, every live feature stays off and the app works as before.

Tests: the traffic, report and geometry rules run anywhere. They use a real Baghdad drive that Valhalla map-matched during development.

```bash
pip install -r requirements-dev.txt
```

```bash
pytest
```

Database tests also run when PostGIS is up: start it with `docker compose up -d db`, then run `pytest` with `DALDAL_TEST_DATABASE_URL=postgresql://daldal:daldal@localhost:5432/daldal` set. If another Postgres already uses port 5432, start the database with `DB_PORT=55432` set and use port 55432 in the URL. All 28 tests pass against PostGIS 16.

**Privacy rules:**
- No accounts.
- GPS probes carry a new random token per trip and no device id.
- The first and last 300 m of every trip never leave the phone.
- Raw points are deleted after matching (at most 10 minutes) and are never in database logs or backups (an UNLOGGED table).
- A road only shows traffic once two different trips have reported on it.
- The API doesn't log IP addresses.
- Reports carry a salted hash of a random install id, only to stop double votes and spam.

## Before launch

- Self-host tiles (Protomaps or OpenMapTiles build of Iraq) and geocoding (Photon). The public OpenFreeMap and Photon instances are for development only (`Daldal/App/AppConfig.swift`).
- Self-host Valhalla for online routing. `valhalla1.openstreetmap.de` is FOSSGIS's fair-use server (`Daldal/Routing/DaldalRouteProvider.swift`). The `Backend/` compose file already runs one.
- Set a real `ID_SALT` for the live server, and put it behind HTTPS.
- Rate limits live in one API process. Before running several API instances, move them to Redis.
- Add App Attest to report and vote requests, so only the real app can post.
- Arabic map labels: verified that the glyph server serves the Arabic ranges (U+0600–06FF and the presentation forms).
