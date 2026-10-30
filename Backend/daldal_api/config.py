import os
from dataclasses import dataclass
from zoneinfo import ZoneInfo


@dataclass(frozen=True)
class Settings:
    database_url: str
    valhalla_url: str
    # Salt for hashing install ids. Rotating it severs every report from its past reporter.
    id_salt: str
    timezone: ZoneInfo


def load() -> Settings:
    return Settings(
        database_url=os.environ.get("DATABASE_URL", "postgresql://daldal:daldal@localhost:5432/daldal"),
        valhalla_url=os.environ.get("VALHALLA_URL", "http://localhost:8002").rstrip("/"),
        id_salt=os.environ.get("ID_SALT", "dev-only-salt-change-me"),
        timezone=ZoneInfo("Asia/Baghdad"),
    )
