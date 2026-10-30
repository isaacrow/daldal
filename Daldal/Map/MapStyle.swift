import Foundation

/// Which colour scheme the map uses. `.auto` follows the system.
enum MapAppearance: String, CaseIterable, Codable, Sendable {
    case auto, day, night

    var icon: DaldalIcon {
        switch self {
        case .auto: .auto
        case .day: .sun
        case .night: .moon
        }
    }

    var next: MapAppearance {
        switch self {
        case .auto: .day
        case .day: .night
        case .night: .auto
        }
    }
}

/// Drawn map or satellite photos (with roads and names on top).
enum MapBaseLayer: String, Codable, Sendable {
    case standard, satellite
}

/// Colours for one map theme.
struct MapPalette: Sendable {
    var background, water, park, wood, residential, building, buildingTop: String
    var roadMinor, roadMinorCasing, roadMajor, roadMajorCasing, motorway, motorwayCasing: String
    var label, labelHalo, waterLabel: String

    static let day = MapPalette(
        background: "#F3F1EC", water: "#A8D0EA", park: "#CDE6C2", wood: "#BEDDB2",
        residential: "#ECE8E1", building: "#E1DCD3", buildingTop: "#EAE6DF",
        roadMinor: "#FFFFFF", roadMinorCasing: "#D8D2C8",
        roadMajor: "#FFE6A3", roadMajorCasing: "#E2BE6E",
        motorway: "#FFC66E", motorwayCasing: "#D99A40",
        label: "#34322E", labelHalo: "#FFFFFF", waterLabel: "#3F6E91"
    )

    static let night = MapPalette(
        background: "#14181D", water: "#0C2131", park: "#15251B", wood: "#132219",
        residential: "#181D23", building: "#20262E", buildingTop: "#2A313A",
        roadMinor: "#2B313A", roadMinorCasing: "#1A1F25",
        roadMajor: "#4B4535", roadMajorCasing: "#2C291F",
        motorway: "#6E5426", motorwayCasing: "#3A2D16",
        label: "#C9CED6", labelHalo: "#0E1114", waterLabel: "#6E9CC0"
    )
}

/// Where vector tiles come from. Both use the OpenMapTiles schema, so one layer list fits both.
enum MapTileSource: Equatable, Sendable {
    /// OpenFreeMap over the internet (plus satellite and terrain, which need the internet).
    case online
    /// The downloaded cities' PMTiles files; used when there's no connection.
    case offline([InstalledCity])

    var cacheKey: String {
        switch self {
        case .online: "online"
        case .offline(let cities): "offline-" + cities.map { "\($0.id)\($0.version)" }.joined(separator: "-")
        }
    }
}

/// Builds a MapLibre style document for the OpenMapTiles vector schema.
///
/// The style lives in code so day, night, satellite, online and offline share one layer list.
/// Offline, each downloaded city is its own source with its own copy of the layers. All shapes are drawn
/// before all labels, so routes and traffic inserted under `labelsAnchor` sit under every city's names.
enum MapStyleBuilder {
    static let buildings3DLayer = "building-3d"
    static let buildingsFlatLayer = "building-flat"
    /// The first label layer. Route lines and traffic are inserted just below it.
    static let labelsAnchor = "road-label"

    /// Label glyphs ship inside the app (Noto Sans, Latin + Arabic), so names render offline everywhere.
    static var glyphsTemplate: String {
        let fonts = Bundle.main.url(forResource: "Fonts", withExtension: nil)
        return (fonts?.absoluteString ?? MapConfig.glyphsURLTemplate.replacingOccurrences(of: "{fontstack}/{range}.pbf", with: ""))
            + "{fontstack}/{range}.pbf"
    }

    static let satelliteTiles = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg"
    static let terrainTiles = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

    static func style(palette p: MapPalette, languageCode: String, tiles: MapTileSource = .online,
                      base: MapBaseLayer = .standard) -> [String: Any] {
        var sources: [String: Any] = [:]
        var sets: [(source: String, suffix: String)] = []
        switch tiles {
        case .online:
            sources["openmaptiles"] = ["type": "vector", "url": MapConfig.vectorTilesURL.absoluteString]
            sets = [("openmaptiles", "")]
        case .offline(let cities):
            for (index, city) in cities.enumerated() {
                let id = "city-\(city.id)"
                // MapLibre Native 6.10+ reads PMTiles straight from disk.
                sources[id] = ["type": "vector", "url": "pmtiles://" + city.mapTiles.absoluteString]
                sets.append((id, index == 0 ? "" : "-\(city.id)"))
            }
        }
        // Satellite and terrain need the internet; offline, the drawn map is used.
        let satellite = base == .satellite && tiles == .online
        if satellite {
            sources["satellite"] = [
                "type": "raster", "tiles": [satelliteTiles], "tileSize": 256, "maxzoom": 14,
                "attribution": "Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data 2016), CC BY 4.0",
            ]
        }
        if tiles == .online {
            sources["terrain"] = [
                "type": "raster-dem", "tiles": [terrainTiles], "tileSize": 256, "maxzoom": 13, "encoding": "terrarium",
                "attribution": "Terrain Tiles (Mapzen, AWS Open Data)",
            ]
        }

        var layers: [[String: Any]] = [
            ["id": "background", "type": "background", "paint": ["background-color": satellite ? "#0B0F0C" : p.background]],
        ]
        if satellite {
            layers.append(["id": "satellite", "type": "raster", "source": "satellite",
                           "paint": ["raster-fade-duration": 150]])
        }
        for set in sets {
            layers += shapes(p, source: set.source, suffix: set.suffix, satellite: satellite, terrain: tiles == .online && set.suffix.isEmpty)
        }
        for set in sets {
            layers += labels(p, source: set.source, suffix: set.suffix, languageCode: languageCode, satellite: satellite)
        }

        return [
            "version": 8,
            "name": "Daldal",
            "sources": sources,
            "glyphs": glyphsTemplate,
            "light": ["anchor": "viewport", "color": "#FFFFFF", "intensity": 0.35, "position": [1.15, 210, 30]],
            "layers": layers,
        ]
    }

    // MARK: Layer sets

    private static func roadWidth(_ base: Double, _ max: Double) -> Any {
        ["interpolate", ["exponential", 1.5], ["zoom"], 5, base, 18, max]
    }

    private static func shapes(_ p: MapPalette, source: String, suffix: String, satellite: Bool, terrain: Bool) -> [[String: Any]] {
        func layer(_ id: String, _ body: [String: Any]) -> [String: Any] {
            var l = body
            l["id"] = id + suffix
            if l["type"] as? String != "hillshade" { l["source"] = source }
            return l
        }
        func roads(_ id: String, classes: [String], color: String, width: Any, minzoom: Double = 0, opacity: Double = 1) -> [String: Any] {
            layer(id, [
                "type": "line", "source-layer": "transportation", "minzoom": minzoom,
                "filter": ["all", ["match", ["get", "class"], classes, true, false], ["!=", ["get", "brunnel"], "tunnel"]],
                "layout": ["line-cap": "round", "line-join": "round"],
                "paint": ["line-color": color, "line-width": width, "line-opacity": opacity],
            ])
        }
        let minor = ["minor", "service", "track"]
        let major = ["primary", "secondary", "tertiary", "trunk"]
        let motorway = ["motorway"]

        if satellite {
            // On photos, only main roads, softly: the picture carries the rest.
            return [
                roads("road-major", classes: major, color: "#FFF4D6", width: roadWidth(0.6, 12), opacity: 0.55),
                roads("motorway", classes: motorway, color: "#FFD27A", width: roadWidth(1, 16), opacity: 0.7),
            ]
        }

        var result: [[String: Any]] = [
            layer("residential", ["type": "fill", "source-layer": "landuse",
                                  "filter": ["==", ["get", "class"], "residential"], "paint": ["fill-color": p.residential]]),
            layer("park", ["type": "fill", "source-layer": "park", "paint": ["fill-color": p.park]]),
            layer("wood", ["type": "fill", "source-layer": "landcover",
                           "filter": ["match", ["get", "class"], ["wood", "grass", "farmland"], true, false],
                           "paint": ["fill-color": p.wood, "fill-opacity": 0.7]]),
        ]
        if terrain {
            // Relief shading: the Kurdistan mountains and the Hamrin hills read at a glance.
            result.append(["id": "hillshade", "type": "hillshade", "source": "terrain", "maxzoom": 15,
                           "paint": ["hillshade-exaggeration": 0.35, "hillshade-shadow-color": "#5A4A3A",
                                     "hillshade-highlight-color": "#FFFFFF", "hillshade-accent-color": "#5A4A3A"]])
        }
        result += [
            layer("water", ["type": "fill", "source-layer": "water", "paint": ["fill-color": p.water]]),
            layer("waterway", ["type": "line", "source-layer": "waterway",
                               "paint": ["line-color": p.water, "line-width": roadWidth(0.5, 6)]]),
            roads("road-minor-casing", classes: minor, color: p.roadMinorCasing, width: roadWidth(0.5, 20), minzoom: 12),
            roads("road-major-casing", classes: major, color: p.roadMajorCasing, width: roadWidth(1, 26)),
            roads("motorway-casing", classes: motorway, color: p.motorwayCasing, width: roadWidth(1.5, 30)),
            roads("road-minor", classes: minor, color: p.roadMinor, width: roadWidth(0.3, 17), minzoom: 12),
            roads("road-major", classes: major, color: p.roadMajor, width: roadWidth(0.8, 22)),
            roads("motorway", classes: motorway, color: p.motorway, width: roadWidth(1.2, 26)),
            layer(buildingsFlatLayer, ["type": "fill", "source-layer": "building", "minzoom": 14,
                                       "layout": ["visibility": "none"],
                                       "paint": ["fill-color": p.building, "fill-outline-color": p.roadMinorCasing]]),
            layer(buildings3DLayer, [
                "type": "fill-extrusion", "source-layer": "building", "minzoom": 14,
                "paint": [
                    "fill-extrusion-color": ["interpolate", ["linear"], ["coalesce", ["get", "render_height"], 0],
                                             0, p.building, 60, p.buildingTop],
                    // Grow buildings out of the ground between z14 and z15 instead of popping in.
                    "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"],
                                              14, 0, 15, ["coalesce", ["get", "render_height"], 0]],
                    "fill-extrusion-base": ["interpolate", ["linear"], ["zoom"],
                                            14, 0, 15, ["coalesce", ["get", "render_min_height"], 0]],
                    "fill-extrusion-opacity": 0.9,
                    "fill-extrusion-vertical-gradient": true,
                ],
            ]),
        ]
        return result
    }

    private static func labels(_ p: MapPalette, source: String, suffix: String, languageCode: String, satellite: Bool) -> [[String: Any]] {
        let name: Any = ["coalesce", ["get", "name:\(languageCode)"], ["get", "name"]]
        // On photos: white names with a dark halo, which read on any ground colour.
        let text = satellite ? "#FFFFFF" : p.label
        let halo = satellite ? "#000000" : p.labelHalo
        return [
            [
                "id": labelsAnchor + suffix, "type": "symbol", "source": source, "source-layer": "transportation_name",
                "minzoom": 13,
                "layout": ["symbol-placement": "line", "text-field": name, "text-font": ["NotoSansRegular"], "text-size": 12],
                "paint": ["text-color": text, "text-halo-color": halo, "text-halo-width": 1.5],
            ],
            [
                "id": "water-label" + suffix, "type": "symbol", "source": source, "source-layer": "water_name",
                "layout": ["text-field": name, "text-font": ["NotoSansItalic"], "text-size": 13],
                "paint": ["text-color": satellite ? "#CFE8FF" : p.waterLabel, "text-halo-color": halo, "text-halo-width": 1],
            ],
            [
                "id": "place-label" + suffix, "type": "symbol", "source": source, "source-layer": "place",
                "layout": [
                    "text-field": name, "text-font": ["NotoSansBold"],
                    "text-size": ["match", ["get", "class"], "city", 17, "town", 15, 13],
                    "text-max-width": 8,
                ],
                "paint": ["text-color": text, "text-halo-color": halo, "text-halo-width": 2],
            ],
        ]
    }

    /// Writes the style to Caches and returns a file URL that `MLNMapView.styleURL` can load.
    static func styleURL(isDark: Bool, languageCode: String, tiles: MapTileSource = .online,
                         base: MapBaseLayer = .standard) throws -> URL {
        let palette = isDark ? MapPalette.night : .day
        let document = style(palette: palette, languageCode: languageCode, tiles: tiles, base: base)
        let data = try JSONSerialization.data(withJSONObject: document)
        let dir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let name = "daldal-style-\(isDark ? "night" : "day")-\(base.rawValue)-\(languageCode)-\(tiles.cacheKey).json"
        let url = dir.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
