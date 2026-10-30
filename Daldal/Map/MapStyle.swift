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

/// Where map tiles and label fonts come from. Both use the OpenMapTiles schema, so one style fits both.
enum MapTileSource: Equatable, Sendable {
    case online
    case offline(InstalledPack)

    var cacheKey: String {
        switch self {
        case .online: "online"
        case .offline(let pack): "offline-\(pack.version)"
        }
    }

    fileprivate var tilesURL: String {
        switch self {
        case .online: MapConfig.vectorTilesURL.absoluteString
        // MapLibre Native 6.10+ reads PMTiles straight from disk.
        case .offline(let pack): "pmtiles://" + pack.mapTiles.absoluteString
        }
    }

    fileprivate var glyphs: String {
        switch self {
        case .online: MapConfig.glyphsURLTemplate
        case .offline(let pack): pack.fontsDirectory.absoluteString + "{fontstack}/{range}.pbf"
        }
    }

    /// Offline font folders have no spaces (see build-iraq-pack.sh), which keeps file URLs valid.
    fileprivate func font(_ weight: String) -> [String] {
        switch self {
        case .online: ["Noto Sans \(weight)"]
        case .offline: ["NotoSans\(weight)"]
        }
    }
}

/// Builds a MapLibre style document for the OpenMapTiles vector schema.
///
/// The style lives in code so day and night share one layer list and only differ by palette.
/// Tiles come from `MapConfig.vectorTilesURL`; Phase 2 swaps that for on-device PMTiles packs.
enum MapStyleBuilder {
    static let buildings3DLayer = "building-3d"
    static let buildingsFlatLayer = "building-flat"

    static func style(palette p: MapPalette, languageCode: String, tiles: MapTileSource = .online) -> [String: Any] {
        let source = "openmaptiles"
        let name: Any = ["coalesce", ["get", "name:\(languageCode)"], ["get", "name"]]

        func roadWidth(_ base: Double, _ max: Double) -> Any {
            ["interpolate", ["exponential", 1.5], ["zoom"], 5, base, 18, max]
        }
        func roads(_ id: String, classes: [String], color: String, width: Any, minzoom: Double = 0) -> [String: Any] {
            [
                "id": id, "type": "line", "source": source, "source-layer": "transportation",
                "minzoom": minzoom,
                "filter": ["all", ["match", ["get", "class"], classes, true, false],
                           ["!=", ["get", "brunnel"], "tunnel"]],
                "layout": ["line-cap": "round", "line-join": "round"],
                "paint": ["line-color": color, "line-width": width],
            ]
        }

        let minor = ["minor", "service", "track"]
        let major = ["primary", "secondary", "tertiary", "trunk"]
        let motorway = ["motorway"]

        let layers: [[String: Any]] = [
            ["id": "background", "type": "background", "paint": ["background-color": p.background]],
            ["id": "residential", "type": "fill", "source": source, "source-layer": "landuse",
             "filter": ["==", ["get", "class"], "residential"],
             "paint": ["fill-color": p.residential]],
            ["id": "park", "type": "fill", "source": source, "source-layer": "park",
             "paint": ["fill-color": p.park]],
            ["id": "wood", "type": "fill", "source": source, "source-layer": "landcover",
             "filter": ["match", ["get", "class"], ["wood", "grass", "farmland"], true, false],
             "paint": ["fill-color": p.wood, "fill-opacity": 0.7]],
            ["id": "water", "type": "fill", "source": source, "source-layer": "water",
             "paint": ["fill-color": p.water]],
            ["id": "waterway", "type": "line", "source": source, "source-layer": "waterway",
             "paint": ["line-color": p.water, "line-width": roadWidth(0.5, 6)]],

            roads("road-minor-casing", classes: minor, color: p.roadMinorCasing, width: roadWidth(0.5, 20), minzoom: 12),
            roads("road-major-casing", classes: major, color: p.roadMajorCasing, width: roadWidth(1, 26)),
            roads("motorway-casing", classes: motorway, color: p.motorwayCasing, width: roadWidth(1.5, 30)),
            roads("road-minor", classes: minor, color: p.roadMinor, width: roadWidth(0.3, 17), minzoom: 12),
            roads("road-major", classes: major, color: p.roadMajor, width: roadWidth(0.8, 22)),
            roads("motorway", classes: motorway, color: p.motorway, width: roadWidth(1.2, 26)),

            [
                "id": buildingsFlatLayer, "type": "fill", "source": source, "source-layer": "building",
                "minzoom": 14, "layout": ["visibility": "none"],
                "paint": ["fill-color": p.building, "fill-outline-color": p.roadMinorCasing],
            ],
            [
                "id": buildings3DLayer, "type": "fill-extrusion", "source": source, "source-layer": "building",
                "minzoom": 14,
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
            ],

            [
                "id": "road-label", "type": "symbol", "source": source, "source-layer": "transportation_name",
                "minzoom": 13,
                "layout": [
                    "symbol-placement": "line", "text-field": name,
                    "text-font": tiles.font("Regular"), "text-size": 12,
                ],
                "paint": ["text-color": p.label, "text-halo-color": p.labelHalo, "text-halo-width": 1.5],
            ],
            [
                "id": "water-label", "type": "symbol", "source": source, "source-layer": "water_name",
                "layout": ["text-field": name, "text-font": tiles.font("Italic"), "text-size": 13],
                "paint": ["text-color": p.waterLabel, "text-halo-color": p.labelHalo, "text-halo-width": 1],
            ],
            [
                "id": "place-label", "type": "symbol", "source": source, "source-layer": "place",
                "layout": [
                    "text-field": name, "text-font": tiles.font("Bold"),
                    "text-size": ["match", ["get", "class"], "city", 17, "town", 15, 13],
                    "text-max-width": 8,
                ],
                "paint": ["text-color": p.label, "text-halo-color": p.labelHalo, "text-halo-width": 2],
            ],
        ]

        return [
            "version": 8,
            "name": "Daldal",
            "sources": [source: ["type": "vector", "url": tiles.tilesURL]],
            "glyphs": tiles.glyphs,
            "light": ["anchor": "viewport", "color": "#FFFFFF", "intensity": 0.35, "position": [1.15, 210, 30]],
            "layers": layers,
        ]
    }

    /// Writes the style to Caches and returns a file URL that `MLNMapView.styleURL` can load.
    static func styleURL(isDark: Bool, languageCode: String, tiles: MapTileSource = .online) throws -> URL {
        let palette = isDark ? MapPalette.night : .day
        let data = try JSONSerialization.data(withJSONObject: style(palette: palette, languageCode: languageCode, tiles: tiles))
        let dir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = dir.appending(path: "daldal-style-\(isDark ? "night" : "day")-\(languageCode)-\(tiles.cacheKey).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
