#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

"""Build bundled Wisconsin-only reference geography for the Shiny app.

This script downloads or reuses local Census/TIGER reference archives,
extracts the Wisconsin-only layers the app uses, and writes them into a single
GeoPackage at `data/reference/wisconsin_reference.gpkg` plus a JSON manifest
file.

Intended outputs:
- layer `counties`
- layer `zctas`
- layer `places`
- layer `roads`
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional
from urllib.parse import urlparse

import geopandas as gpd
import requests

TARGET_STATE = "WI"
TARGET_STATE_FIPS = "55"
CENSUS_ZCTA_URL = "https://www2.census.gov/geo/tiger/GENZ2020/shp/cb_2020_us_zcta520_500k.zip"
CENSUS_COUNTY_URL = "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_us_county_20m.zip"
CENSUS_PLACE_URL = "https://www2.census.gov/geo/tiger/GENZ2024/shp/cb_2024_55_place_500k.zip"
CENSUS_PRISECROADS_URL = "https://www2.census.gov/geo/tiger/TIGER2025/PRISECROADS/tl_2025_55_prisecroads.zip"


@dataclass(frozen=True)
class SourceSpec:
    name: str
    url: str
    layer_name: str
    cli_flag: str


SOURCES = [
    SourceSpec("counties", CENSUS_COUNTY_URL, "counties", "county-archive"),
    SourceSpec("zctas", CENSUS_ZCTA_URL, "zctas", "zcta-archive"),
    SourceSpec("places", CENSUS_PLACE_URL, "places", "place-archive"),
    SourceSpec("roads", CENSUS_PRISECROADS_URL, "roads", "roads-archive"),
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download_file(url: str, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=300) as response:
        response.raise_for_status()
        with dest.open("wb") as fh:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    fh.write(chunk)
    return dest


def materialize_source_archive(spec: SourceSpec, scratch: Path, override_archive: Optional[Path]) -> tuple[Path, dict]:
    if override_archive is not None:
        archive_path = override_archive.expanduser().resolve()
        if not archive_path.exists():
            raise FileNotFoundError(f"Override archive for {spec.name} not found: {archive_path}")
        return archive_path, {
            "type": "local_archive",
            "path": str(archive_path),
            "sha256": sha256_file(archive_path),
        }

    archive_name = Path(urlparse(spec.url).path).name
    archive_path = download_file(spec.url, scratch / archive_name)
    return archive_path, {
        "type": "remote_download",
        "url": spec.url,
        "cached_path": str(archive_path),
        "sha256": sha256_file(archive_path),
    }


def unzip_to_dir(archive_path: Path, dest_dir: Path) -> Path:
    shutil.unpack_archive(str(archive_path), str(dest_dir))
    shp_files = sorted(dest_dir.rglob("*.shp"))
    if not shp_files:
        raise FileNotFoundError(f"No shapefile found inside {archive_path}")
    return shp_files[0]


def load_source_frame(spec: SourceSpec, scratch: Path, override_archive: Optional[Path]) -> tuple[gpd.GeoDataFrame, dict]:
    archive_path, archive_meta = materialize_source_archive(spec, scratch, override_archive)
    unpack_dir = scratch / spec.name
    unpack_dir.mkdir(parents=True, exist_ok=True)
    shp_path = unzip_to_dir(archive_path, unpack_dir)
    frame = gpd.read_file(shp_path)
    if frame.crs is None:
        frame = frame.set_crs(4269)
    return frame.to_crs(4326), archive_meta


def prepare_counties(frame: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    frame = frame.loc[frame["STATEFP"] == TARGET_STATE_FIPS, ["NAME", "GEOID", "COUNTYFP", "geometry"]].copy()
    return frame.reset_index(drop=True)


def prepare_zctas(frame: gpd.GeoDataFrame, counties: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    frame = frame.rename(columns={"GEOID20": "zipcode"})[["zipcode", "geometry"]].copy()
    state_union = counties.union_all() if hasattr(counties, "union_all") else counties.unary_union
    frame = frame.loc[frame.intersects(state_union)].copy().reset_index(drop=True)
    county_points = frame.copy()
    county_points["geometry"] = county_points.representative_point()
    joined = gpd.sjoin(county_points, counties[["NAME", "GEOID", "geometry"]], predicate="intersects", how="left")
    frame["county_geoid"] = joined["GEOID"].values
    frame["county_name"] = joined["NAME"].values
    return frame


def prepare_places(frame: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    keep_cols = [c for c in ["NAME", "NAMELSAD", "geometry"] if c in frame.columns]
    frame = frame[keep_cols].copy()
    if "NAME" not in frame.columns and "NAMELSAD" in frame.columns:
        frame = frame.rename(columns={"NAMELSAD": "NAME"})
    return frame.reset_index(drop=True)


def prepare_roads(frame: gpd.GeoDataFrame, counties: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    keep_cols = [c for c in ["LINEARID", "FULLNAME", "RTTYP", "MTFCC", "geometry"] if c in frame.columns]
    frame = frame[keep_cols].copy()
    state_union = counties.union_all() if hasattr(counties, "union_all") else counties.unary_union
    frame = frame.loc[frame.intersects(state_union)].copy().reset_index(drop=True)
    frame["road_id"] = frame["LINEARID"].astype(str)
    road_name = frame["FULLNAME"].fillna("").astype(str).str.strip()
    road_class = frame["MTFCC"].map(lambda x: "Primary" if x == "S1100" else "Secondary")
    fallback_name = road_class.map(lambda x: f"{x} road")
    frame["road_name"] = road_name.where(road_name.str.len() > 0, fallback_name)
    frame["road_class"] = road_class
    frame["susceptibility"] = frame["road_class"].map({"Primary": 1.0, "Secondary": 0.85}).fillna(0.85)
    return frame


def write_manifest(path: Path, layer_frames: Dict[str, gpd.GeoDataFrame], output_path: Path, source_meta: dict) -> None:
    manifest = {
        "built_at_utc": datetime.now(timezone.utc).isoformat(),
        "output_file": str(output_path),
        "output_sha256": sha256_file(output_path),
        "sources": {spec.layer_name: spec.url for spec in SOURCES},
        "resolved_sources": source_meta,
        "layers": {
            layer: {
                "rows": int(len(frame)),
                "columns": [c for c in frame.columns if c != "geometry"],
                "crs": str(frame.crs),
            }
            for layer, frame in layer_frames.items()
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2))


def build_reference_assets(output_path: Path, manifest_path: Path, archive_overrides: dict[str, Optional[Path]]) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()
    if manifest_path.exists():
        manifest_path.unlink()

    with tempfile.TemporaryDirectory(prefix="wi_ref_build_") as td:
        scratch = Path(td)
        raw = {}
        source_meta = {}
        for spec in SOURCES:
            frame, meta = load_source_frame(spec, scratch, archive_overrides.get(spec.name))
            raw[spec.name] = frame
            source_meta[spec.layer_name] = meta

        counties = prepare_counties(raw["counties"])
        zctas = prepare_zctas(raw["zctas"], counties)
        places = prepare_places(raw["places"])
        roads = prepare_roads(raw["roads"], counties)

        layer_frames = {
            "counties": counties,
            "zctas": zctas,
            "places": places,
            "roads": roads,
        }
        for layer, frame in layer_frames.items():
            frame.to_file(output_path, layer=layer, driver="GPKG")

        write_manifest(manifest_path, layer_frames, output_path, source_meta)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build bundled Wisconsin reference geography.")
    parser.add_argument("--output", default="data/reference/wisconsin_reference.gpkg", help="Path to output GeoPackage.")
    parser.add_argument("--manifest", default="data/reference/wisconsin_reference_manifest.json", help="Path to manifest JSON.")
    parser.add_argument("--county-archive", default=None, help="Optional local county TIGER/GENZ zip archive.")
    parser.add_argument("--zcta-archive", default=None, help="Optional local ZCTA TIGER/GENZ zip archive.")
    parser.add_argument("--place-archive", default=None, help="Optional local place TIGER/GENZ zip archive.")
    parser.add_argument("--roads-archive", default=None, help="Optional local roads TIGER/GENZ zip archive.")
    args = parser.parse_args()
    overrides = {
        "counties": Path(args.county_archive) if args.county_archive else None,
        "zctas": Path(args.zcta_archive) if args.zcta_archive else None,
        "places": Path(args.place_archive) if args.place_archive else None,
        "roads": Path(args.roads_archive) if args.roads_archive else None,
    }
    build_reference_assets(Path(args.output), Path(args.manifest), overrides)
    print(f"Wrote {args.output}")
    print(f"Wrote {args.manifest}")


if __name__ == "__main__":
    main()
