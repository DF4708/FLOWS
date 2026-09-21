<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

Reference inputs the build tools read. Everything here is gitignored except
this README; each file is fetched or written by the tool named beside it.

- `fsq_places_us.tsv`: the Foursquare OS Places rows for the US, written by
  `scripts/fsq_places_to_tsv.sh` (curl and the DuckDB command-line tool) and
  compiled into place shards by `scripts/build_places_shards.sh`.
- `2024_Gaz_zcta_national.txt`, `tab20_zcta520_county20_natl.txt` (Census)
  and `nws_zone_county.dbx` (NWS): read by flows-train's `history-baseline`
  and `national-bundle` through `scripts/build_history_baseline.sh`.

The Wisconsin reference geography that used to live here
(`wisconsin_reference.gpkg` and its manifest) was retired with the R engine
in c8a903e, together with its builder and validator. FLOWS has no Python.
