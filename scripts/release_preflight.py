#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# Contact: d.foster@marquette.edu
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------

"""Run release-oriented checks for the Wisconsin Shiny app bundle.

This script is intentionally executable even in constrained environments. It:
- validates the bundled Wisconsin reference assets when present
- reports clearly when the reference assets are absent
- runs the R runtime smoke test when Rscript is available
"""

from __future__ import annotations

import argparse
import importlib.util
import shutil
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], cwd: Path) -> int:
    proc = subprocess.run(cmd, cwd=str(cwd))
    return proc.returncode


def python_validation_supported() -> bool:
    return (
        importlib.util.find_spec("fiona") is not None
        and importlib.util.find_spec("geopandas") is not None
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run release preflight checks.")
    parser.add_argument("--project-dir", default=".", help="Repository root containing global.R/ui.R/server.R")
    parser.add_argument("--require-assets", action="store_true", help="Fail when the bundled reference assets are missing.")
    parser.add_argument("--require-r", action="store_true", help="Fail when Rscript is missing.")
    args = parser.parse_args()

    project_dir = Path(args.project_dir).resolve()
    scripts_dir = project_dir / "scripts"
    gpkg_path = project_dir / "data" / "reference" / "wisconsin_reference.gpkg"
    manifest_path = project_dir / "data" / "reference" / "wisconsin_reference_manifest.json"

    failed = False
    rscript = shutil.which("Rscript")

    if gpkg_path.exists() and manifest_path.exists():
        print("Running bundled-reference validation...")
        if python_validation_supported():
            rc = run(
                [
                    sys.executable,
                    str(scripts_dir / "validate_wisconsin_reference_assets.py"),
                    "--gpkg",
                    str(gpkg_path),
                    "--manifest",
                    str(manifest_path),
                ],
                project_dir,
            )
        else:
            print("Python GIS packages (fiona, geopandas) are not available; cannot validate bundled assets.")
            rc = 1
        failed = failed or (rc != 0)
    else:
        print("Bundled Wisconsin reference assets are not present.")
        if args.require_assets:
            failed = True

    if rscript is None:
        print("Rscript is not available in this environment.")
        if args.require_r:
            failed = True
    else:
        print("Running R runtime smoke test...")
        rc = run([rscript, str(scripts_dir / "runtime_smoke_test.R"), str(project_dir)], project_dir)
        failed = failed or (rc != 0)

    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
