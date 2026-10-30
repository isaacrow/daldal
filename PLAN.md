# دلدل (Daldal) — iOS Navigation App: Build Plan

Target: iOS 26+, Swift 6, SwiftUI, Liquid Glass. No Google Maps, no Apple MapKit for the map itself.
**Region: Iraq only.** Search, map packs, routing graph, road signs, voice and heritage content all cover Iraq and nothing else (see `Daldal/App/Region.swift`).

**Progress:** Phases 1–3 are written. Phase 3 adds the live server and live traffic, reports, faster routes and closures in the app. The backend's rules are tested (24 tests on real Baghdad map-matching data). The iOS app hasn't been compiled yet, because that needs a Mac.

---

## 0. Ground rules (what we will NOT do, and what we do instead)

| Asked for | Problem | What we do instead |
|---|---|---|
| Reverse-engineer the Waze app | Breaks Waze's terms and copyright law. Decompiled code also can't ship on the App Store. | Build the same *behaviour* from public, well-documented algorithms (below). Waze's ideas — live traffic, rerouting, reports — are not secret. |
| Bot that copies places and coordinates from Waze / Google Maps | Google Maps Platform terms ban scraping and caching. Waze data is proprietary. The app would be rejected or sued. | Use open data that you're allowed to ship: **OpenStreetMap** (ODbL) for roads and places, plus **Overture Maps Places** (open licence, 50M+ POIs). Your own users' reports grow the data over time, the way Waze did. |
| Full AR camera view while driving | A driver looking at a camera feed is a crash risk. Apple reviews this. | The AR/vision engine runs as a **dashcam brain**: it reads signs, lanes and cars from the camera and feeds *alerts and voice*, not a screen to stare at. The full AR view is for passengers or when parked. |

---

## 1. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Map renderer | **MapLibre Native iOS** (Metal) + **MapLibre SwiftUI DSL** | Open source, vector tiles, 3D extruded buildings, terrain, offline packs. |
| Map data / tiles | **OpenStreetMap** → **Protomaps PMTiles** (or OpenMapTiles schema) | One file per region, which is what makes maps downloadable. You can host it on any CDN, so there's no per-request bill. |
| 3D terrain | Mapterhorn / AWS Terrain Tiles (terrarium DEM) | Real elevation for the 3D map. |
| Routing engine | **Valhalla** (C++, offline-capable) | Same class of engine as big nav apps: time-dependent costing, turn restrictions, live traffic hooks, multiple vehicle profiles. |
| Turn-by-turn core | **Ferrostar** (Stadia Maps, Rust core + SwiftUI) | Production-ready. Handles route progress, off-route detection, rerouting and spoken instructions. Lets us plug in our own on-device Valhalla. |
| Search / geocoding | **Pelias** or **Photon** server (OSM + Overture), plus an on-device SQLite FTS5 index for offline regions | Address and place search without Google. |
| Live traffic + reports | Our own backend (Swift Vapor or Go) + PostGIS + Redis + WebSockets | This is where the "Waze brain" lives (section 3). |
| Voice | `AVSpeechSynthesizer` with Premium/Enhanced voices + custom earcons | Better-sounding directions (section 6). |
| AR / vision | ARKit + RealityKit + Vision + Core ML (YOLO-class detector, sign classifier) | Section 5. |
| UI | SwiftUI + Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`) | Section 4. |
| Car | CarPlay navigation template (needs Apple's `carplay-maps` entitlement) | Phase 4. |

---

## 2. App architecture

MV + `@Observable` stores, injected services. TCA isn't needed for this app.

```
Daldal/
  App/                DaldalApp.swift, AppRouter, DI container
  DesignSystem/       Glass components, colours, typography, Icons/ (SVG assets only — zero emoji)
  Map/                MapLibre view, styles (day/night/3D), camera controller
  Offline/            Region downloader (PMTiles + routing graph + search index), storage manager
  Routing/            Valhalla wrapper, Ferrostar session, route ranking, reroute policy
  Navigation/         DriveMode UI, maneuver banner, lane guidance, speed panel, ETA bar
  Voice/              Instruction phraser (Arabic + English), speech engine, audio session ducking
  Search/             Online (Pelias) + offline (FTS5) search, recents, favourites
  Reports/            Police / crash / hazard / jam reporting + confirmations
  Traffic/            Live speed ingest, probe uploader (anonymised GPS traces)
  Vision/             Camera pipeline, Core ML detectors, sign/lane/vehicle catalogue
  AR/                 RealityKit AR view (passenger / parked mode)
  CarPlay/            CPTemplateApplicationSceneDelegate
  Settings/
Backend/              (separate repo) traffic, reports, tiles, search
```

---

## 3. The "Waze brain" — algorithms, built from public sources

1. **Routing core:** Valhalla tiled graph with bidirectional A*. For long trips, contraction-hierarchy-style shortcuts.
2. **Live traffic:** users send anonymised GPS probes every few seconds while driving.
   - Map-match the probes to road segments with a Hidden Markov Model (Newson & Krumm 2009, which Valhalla's Meili implements).
   - Compute the current speed per segment, smooth it with an exponential moving average, and compare it with the historic speed for that time of week.
   - Push the result into Valhalla's live-traffic tiles.
3. **Predictive ETA:** historic speed profile per segment × 15-minute bucket × weekday, blended with the live value. Later, a small gradient-boosted model trained on our own trips.
4. **Rerouting:** re-solve every 60–120 s and whenever the ETA changes by more than X%. Only offer a new route if it saves at least max(2 min, 10%). This stops the route flipping back and forth.
5. **Reports:** police, crash, hazard, closure, and so on, each with a time decay. Other drivers confirm or dismiss reports as they pass, and each reporter builds up a trust score. A closure report changes routing costs.
6. **Off-route detection:** Ferrostar's built-in check plus our own threshold based on heading and distance. It's faster in cities and tolerant on highways.
7. **Speed cameras / speed limits:** OSM `maxspeed` and speed-camera tags, plus user reports, plus speed limits read from road signs by the vision module.

---

## 4. UI — Drive Mode first

- **Two states:** *Explore* (search, browse the 3D map) and *Drive* (the whole UI is dedicated to driving).
- **Drive Mode:** pitched 3D camera follows the car heading. Top glass banner shows the next maneuver with a large SVG arrow and lane guidance. Bottom glass bar shows ETA, time left and distance left. Speed panel shows your speed against the limit and turns red when you're over. Report button is one big glass button reachable with your thumb. Everything else is hidden. Night style switches on automatically from sun position.
- **Liquid Glass:** controls float over the map inside a `GlassEffectContainer`. Moving from Explore to Drive morphs the panels using `glassEffectID`. Only real controls are interactive. Respect *Reduce Transparency* and fall back to solid material.
- **Icons:** every icon is an SVG in the asset catalog (Preserve Vector Data), designed on one 24-pt grid. A lint script in CI fails the build if any emoji appears in the source.
- **Right-to-left first:** Arabic is the main language. The layout mirrors, and distances and numbers follow the user's locale.

---

## 5. AR / XR and vision (real, on-device)

- **Pipeline:** `AVCaptureSession` or `ARSession` frames → Vision `CoreMLRequest`.
  - **Vehicle / pedestrian / cyclist detector:** a YOLO-class model converted with coremltools and quantised to int8 for the Neural Engine. Runs at 15–30 fps.
  - **Traffic-sign classifier:** trained on GTSRB plus Mapillary Traffic Sign Dataset (check its licence), fine-tuned for Gulf/Arabic signs. Reads speed limits and stop/yield signs.
  - **Lane detection:** a small segmentation model.
- **Real depth, not faked:**
  - On LiDAR iPhones, use `ARWorldTrackingConfiguration` with `.sceneDepth`.
  - On other iPhones, use a monocular depth model (Depth Anything V2 small as Core ML).
  - Combine depth with each detection box to get real distance to the car ahead, which drives the time-to-collision warning.
- **Catalogue:** detected signs with GPS and confidence go into a local store. With the user's permission they're uploaded to the backend, where several drivers' sightings are merged to confirm each sign on the map. Faces and plates are blurred on-device before anything is uploaded.
- **AR view (passenger / parked):** RealityKit `RealityView` draws route arrows anchored on the road, using ARKit geo-tracking where available and plane anchors elsewhere.
- **Thermal and battery:** watch `ProcessInfo.thermalState` and drop the frame rate or model size when the phone gets hot.

---

## 5b. Geographic AR at monuments (built in Phase 1)

When someone walks into a monument or visitor site, they can open AR and see the site's 3D model standing where it really is.

- **Why not Apple's geo anchors:** `ARGeoTrackingConfiguration` only works in Apple's supported cities, and Iraq isn't one of them.
- **How we anchor instead:**
  - World tracking aligned to true north (`.gravityAndHeading`).
  - GPS converted into an east/north offset in metres (`GeoMath`), placed once the fix is better than 25 m.
  - The anchor is moved again whenever GPS gets clearly better.
  - The user can drag sideways to correct leftover compass error.
- **Real depth:** on LiDAR iPhones, the scanned scene mesh and people segmentation hide the model behind real walls and people.
- **Far sites:** a site 1 km away is drawn 120 m away and shrunk by the same factor, so it looks the same but stays stable. The label and the light-column marker keep a constant on-screen size.
- **Content:** USDZ per site (`modelURL` in `iraq-heritage.json`), downloaded once and cached. With no model, a light column and a name label mark the site.
- **Arrival:** within 400 m of a site (with GPS better than 100 m), a glass banner offers "View in AR".
- **Safety:** AR pauses above 4 m/s, so it never runs for a driver.
- **Next:**
  - Make models with Apple Object Capture, starting with the Ziggurat of Ur, Ishtar Gate, Malwiya of Samarra and Taq Kasra.
  - Add audio-guide narration per site.
  - Add historical "then and now" reconstructions.
  - Background arrival alerts with `CLMonitor`, which need Always location; ask only when the user opts in.

---

## 5c. Phase 2 decisions (from testing real data)

- **Our own Arabic voice text.** Valhalla's `ar-SA` narration, tested on a real Baghdad route, mixed in English ("Drive southwest") and dropped numbers ("اكمل لغاية كيلومترات"). Daldal requests English data and writes instructions itself (`ManeuverPhraser`) from maneuver type, direction, road name and roundabout exit.
- **Timing like Waze.** An early heads-up at 400 m, 1 km or 2 km depending on speed. A final prompt about 9 seconds before the turn. Close turns are chained ("…ثم التزم المسار الأيمن"). After a turn onto a long road, "continue for X km".
- **One request shape.** Ferrostar's Valhalla request generator builds the request for both the server and the on-device router, and Ferrostar's OSRM parser reads both replies.
- **Arabic search normalization.** Tested with SQLite FTS5: harakat split words, so vowelled names couldn't be found. The index builder and the app now fold harakat, tatweel, alef/hamza forms, ى→ي and ة→ه the same way.
- **Iraq-tuned routing.** Valhalla is told to prefer main roads and avoid tracks. Deviation tolerance is 35 m, because GPS in dense Baghdad blocks drifts.

---

## 5d. Phase 3 decisions

- **Traffic without a road database.** Valhalla's map matcher snaps each trip to graph edges. Each edge's speed is the median of the phones' own GPS speeds, which are accurate to about 1 km/h, rather than distance over time.
- **Free-flow speed learns.** It starts from Valhalla's OSM-based estimate, which is often wrong in Iraq. It rises when cars go faster than it, and settles toward night-time speeds.
- **Live ETA without rebuilding the graph.** `/v1/eta` map-matches a route's own shape to edges and adds up the live delay. The app adds that delay to Valhalla's duration, so route options and faster-route checks compare like with like.
- **Faster route.** Every 2 minutes while driving, the app asks for routes from where you are. It only interrupts for a saving of at least 2 minutes or 10%, and only on a genuinely different road (less than 85% overlap).
- **Reports.**
  - A report of the same thing nearby confirms the existing one instead of adding a second pin.
  - Reports expire on their own, and two "gone" votes outweigh a lone reporter.
  - Reports from reporters with a poor track record stay hidden until someone else confirms them.
- **Closures change routing only after two drivers confirm them.** They become `exclude_polygons` in every route request, on the phone or on the server.
- **Next:** historical speed profiles per road and 15-minute slot, for predicted ETAs at departure time.

---

## 6. Better voice

- Use Premium/Enhanced system voices (Arabic and English). The phrasing is ours: short, timed by speed (for example "In 400 metres, keep right, then exit"), and ending with the street name.
- The audio session ducks music instead of pausing it, and works with spoken-audio apps (podcasts pause).
- A soft custom chime plays before each instruction. Volume adapts to how fast you're driving.
- Optional later: a custom neural voice for the brand (bundled Core ML TTS model).

---

## 7. Downloadable maps

A region pack contains:
- the PMTiles vector map
- the Valhalla routing tiles
- the SQLite search index
- the DEM terrain.

Download runs as a background `URLSession` with resume. Packs are versioned and get delta updates. A storage screen shows the size of each region. When a pack is installed, the app works fully offline: map, search, routing and voice. Live traffic is the only feature that needs a connection.

---

## 8. Phases

| Phase | Deliverable |
|---|---|
| **1 — Foundation** | Xcode project, design system, SVG icon set, logo, MapLibre 3D map with our own style, search, Explore UI with Liquid Glass |
| **2 — Navigation** | Valhalla + Ferrostar, Drive Mode UI, voice, rerouting, offline region packs |
| **3 — Waze brain** | Backend, probes, live traffic, reports, predictive ETA |
| **4 — Vision / AR** | Core ML detectors, depth, sign catalogue, collision warning, AR passenger view, CarPlay |
| **5 — Ship** | Privacy manifest, location and camera permission copy, TestFlight, App Store review |

---

## 8b. Open-source additions (checked for licence before use)

| Project | What it adds to Daldal | Licence / caveat |
|---|---|---|
| **Wikidata + Wikimedia Commons** | Heritage catalogue, names in Arabic and English, photos (in use now) | CC0 data. Photos are credited per file. |
| **Geofabrik Iraq extract** | Single OSM source for map, routing and search packs | ODbL, attribution required |
| **Protomaps `pmtiles extract`** | Iraq-only offline vector map in one file. Same idea as Aleph's "download an area". | BSD |
| **Valhalla** | Offline routing on device (Phase 2) | MIT |
| **Ferrostar** | Turn-by-turn engine and SwiftUI navigation views | BSD-3 |
| **Mapterhorn / AWS Terrain Tiles** | Real 3D terrain (Kurdistan mountains, the Hamrin hills) | Open terrain data, attribution |
| **Overture Maps Places** | Extra shops, fuel stations and restaurants that OSM lacks in Iraq | CDLA-Permissive 2.0. Check each release. |
| **Piper TTS voices via sherpa-onnx** | Natural neural Arabic voice on device, offline | The engine is open source. Each voice has its own licence, so check before shipping. |
| **adhan-swift** | Prayer times and Qibla, plus nearest mosque from OSM | MIT |
| **Open-Meteo** | Weather plus dust and air-quality forecasts. Dust-storm warnings for drivers. | CC BY 4.0 data |
| **Depth Anything V2 Small (Apple's Core ML build)** | Real depth on non-LiDAR iPhones for the vision module | Apache-2.0 for the Small model only |
| **RT-DETR** | Car, pedestrian and sign detector. Use it instead of Ultralytics YOLO, which is AGPL and would force the app open-source. | Apache-2.0 |
| **GTSRB + our own Iraqi sign photos** | Road-sign classifier. The Mapillary sign dataset is non-commercial, so only use it for research. | Varies by dataset |
| **OSM `highway=speed_camera`, `maxspeed`** | Speed cameras and limits | ODbL |

**Aleph (belluxx/aleph):** we copy its idea, not its code. Its Google imagery and 3D meshes come from undocumented Google endpoints, which we can't ship. Its open sources (OSM buildings, AWS terrain, OpenFreeMap) are already our stack, and its "draw an area and get everything" flow becomes our Iraq offline-pack builder.

**Iraq-specific features to add:**
- Kurdish (Sorani) language, using OSM `name:ckb` tags.
- Hijri dates (Foundation's `.islamicUmmAlQura` calendar).
- Arbaeen pilgrimage mode: walking routes and crowd reports on the Najaf–Karbala road.
- Fuel-queue reports, written in Iraqi dialect for the report UI.

---

## 9. What's needed from you

1. **A Mac with Xcode 26.** This PC runs Windows. iOS apps can only be compiled, signed and run on macOS (your own Mac, or a cloud Mac such as MacinCloud or GitHub Actions macOS runners). I can write all the code here, but I can't build or test it on this machine.
2. **The logo (img 1).** It didn't come through. Drop it into this folder.
3. **Apple Developer account** ($99/year), needed for devices, TestFlight and the CarPlay entitlement.
4. ~~Target region~~ Decided: Iraq.
5. **Server budget** for tiles, search and traffic. A small VPS plus a CDN is enough to start.
