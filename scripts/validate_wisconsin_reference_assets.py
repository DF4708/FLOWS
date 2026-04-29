#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

"""Validate bundled Wisconsin reference geography assets for release packaging.

This script checks that the Wisconsin GeoPackage and companion manifest exist,
that all required layers are present and non-empty, that manifest metadata
matches the actual packaged layers, and that the manifest digest matches the
actual GeoPackage digest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import fiona
import geopandas as gpd

EXPECTED_LAYERS = ("counties", "zctas", "places", "roads")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_manifest(path: Path) -> dict:
    if not path.exists():
        fail(f"Manifest not found: {path}")
    try:
        return json.loads(path.read_text())
    except Exception as exc:  # pragma: no cover - defensive
        fail(f"Could not parse manifest {path}: {exc}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate bundled Wisconsin reference assets.")
    parser.add_argument("--gpkg", default="data/reference/wisconsin_reference.gpkg", help="Path to GeoPackage.")
    parser.add_argument("--manifest", default="data/reference/wisconsin_reference_manifest.json", help="Path to manifest JSON.")
    args = parser.parse_args()

    gpkg_path = Path(args.gpkg)
    manifest_path = Path(args.manifest)

    if not gpkg_path.exists():
        fail(f"GeoPackage not found: {gpkg_path}")

    manifest = load_manifest(manifest_path)
    manifest_layers = manifest.get("layers") or {}

    if not manifest.get("built_at_utc"):
        fail("Manifest is missing built_at_utc")

    declared_output = manifest.get("output_file")
    if declared_output and Path(declared_output).name != gpkg_path.name:
        fail(f"Manifest output_file does not match the validated GeoPackage name: manifest={declared_output}, file={gpkg_path.name}")

    declared_sha = manifest.get("output_sha256")
    actual_sha = sha256_file(gpkg_path)
    if declared_sha and declared_sha != actual_sha:
        fail(f"GeoPackage sha256 mismatch: manifest={declared_sha}, actual={actual_sha}")

    try:
        available_layers = set(fiona.listlayers(gpkg_path))
    except Exception as exc:  # pragma: no cover - defensive
        fail(f"Could not inspect layers in {gpkg_path}: {exc}")

    missing = [layer for layer in EXPECTED_LAYERS if layer not in available_layers]
    if missing:
        fail(f"GeoPackage is missing required layers: {', '.join(missing)}")

    for layer in EXPECTED_LAYERS:
        if layer not in manifest_layers:
            fail(f"Manifest does not declare required layer: {layer}")

        frame = gpd.read_file(gpkg_path, layer=layer)
        if frame.empty:
            fail(f"Layer {layer} is empty")

        expected_rows = manifest_layers[layer].get("rows")
        if expected_rows is not None and int(expected_rows) != len(frame):
            fail(f"Layer {layer} row count mismatch: manifest={expected_rows}, actual={len(frame)}")

        declared_columns = tuple(manifest_layers[layer].get("columns") or [])
        actual_columns = tuple(col for col in frame.columns if col != "geometry")
        if declared_columns and declared_columns != actual_columns:
            fail(f"Layer {layer} column mismatch: manifest={declared_columns}, actual={actual_columns}")

    print(f"Validated {gpkg_path}")
    print(f"Validated {manifest_path}")
    print("All required Wisconsin reference layers are present and match the manifest.")


if __name__ == "__main__":
    main()
