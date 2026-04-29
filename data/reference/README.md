Bundled Wisconsin reference geography belongs in this folder.

Expected release artifacts:
- `wisconsin_reference.gpkg`
- `wisconsin_reference_manifest.json`

Use `scripts/build_wisconsin_reference_assets.py` to generate them on a machine with internet access, then run `scripts/validate_wisconsin_reference_assets.py` before shipping a `USE_LOCAL_REFERENCE_ONLY=true` build.

If you already downloaded the Census/TIGER zip archives on another machine, the builder can consume them directly with `--county-archive`, `--zcta-archive`, `--place-archive`, and `--roads-archive` instead of re-downloading them.
