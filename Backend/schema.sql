-- Daldal live data. Applied at startup (idempotent).
CREATE EXTENSION IF NOT EXISTS postgis;

-- Raw GPS points live here for seconds to minutes: the worker claims and deletes them after
-- map matching, and anything older than 10 minutes is purged. UNLOGGED: never in WAL or backups.
CREATE UNLOGGED TABLE IF NOT EXISTS probe_points (
    id          bigserial PRIMARY KEY,
    trip        uuid        NOT NULL,  -- random per trip, generated on the phone; not tied to a device
    t           timestamptz NOT NULL,
    lat         double precision NOT NULL,
    lon         double precision NOT NULL,
    speed       real,
    accuracy    real NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS probe_points_received ON probe_points (received_at);

-- Current speed per road edge (Valhalla graph edge id). Only aggregates, never individual trips.
CREATE TABLE IF NOT EXISTS traffic_live (
    edge_id      bigint PRIMARY KEY,
    way_id       bigint NOT NULL,
    geom         geometry(LineString, 4326) NOT NULL,
    length_m     real NOT NULL,
    valhalla_kph real NOT NULL,
    freeflow_kph real NOT NULL,
    speed_kph    real NOT NULL,
    trips        integer NOT NULL,
    last_trip    text NOT NULL,
    updated_at   timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS traffic_live_geom ON traffic_live USING gist (geom);
CREATE INDEX IF NOT EXISTS traffic_live_updated ON traffic_live (updated_at);

CREATE TABLE IF NOT EXISTS reports (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    type        text NOT NULL,
    geom        geometry(Point, 4326) NOT NULL,
    heading     real,
    reporter    text NOT NULL,  -- salted hash of the app's random install id
    up          integer NOT NULL DEFAULT 1,
    down        integer NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    removed     boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS reports_geom ON reports USING gist (geom);
CREATE INDEX IF NOT EXISTS reports_active ON reports (expires_at) WHERE NOT removed;

CREATE TABLE IF NOT EXISTS report_votes (
    report_id   uuid NOT NULL REFERENCES reports (id) ON DELETE CASCADE,
    voter       text NOT NULL,
    still_there boolean NOT NULL,
    at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (report_id, voter)
);

CREATE TABLE IF NOT EXISTS reporters (
    reporter  text PRIMARY KEY,
    confirmed integer NOT NULL DEFAULT 0,
    rejected  integer NOT NULL DEFAULT 0
);
