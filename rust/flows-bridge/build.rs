// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// -----------------------------------------------------------------------------

//! Regenerates the Swift and C half of the bridge from the declarations.
//!
//! Output is written to a scratch directory first and copied into
//! `apple/FLOWS/RustBridge/` only when a file's bytes changed, so a rebuild
//! does not touch timestamps and make Xcode recompile. The generated files are
//! committed and never hand-edited (3.25.5); CI regenerates and fails on any
//! difference.

#![forbid(unsafe_code)]

use std::fs;
use std::path::{Path, PathBuf};

const BRIDGES: &[&str] = &[
    "src/alert_text.rs",
    "src/alerts.rs",
    "src/climate.rs",
    "src/forecast.rs",
    "src/geo.rs",
    "src/hazard_feeds.rs",
    "src/learning.rs",
    "src/long_trips.rs",
    "src/modes.rs",
    "src/places.rs",
    "src/places_text.rs",
    "src/recents_and_rides.rs",
    "src/risk.rs",
    "src/risk_field.rs",
    "src/seasonal.rs",
    "src/tags_and_replies.rs",
    "src/trip_vehicle.rs",
    "src/vehicle_policy.rs",
];

fn copy_if_changed(from: &Path, to: &Path) -> std::io::Result<()> {
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let src = entry.path();
        let dst = to.join(entry.file_name());
        if src.is_dir() {
            fs::create_dir_all(&dst)?;
            copy_if_changed(&src, &dst)?;
        } else {
            let new = fs::read(&src)?;
            if fs::read(&dst).ok().as_deref() != Some(new.as_slice()) {
                fs::write(&dst, new)?;
            }
        }
    }
    Ok(())
}

fn main() {
    for b in BRIDGES {
        println!("cargo:rerun-if-changed={b}");
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("cargo sets OUT_DIR")).join("swift");
    let _ = fs::remove_dir_all(&out);
    swift_bridge_build::parse_bridges(BRIDGES.iter().map(|b| manifest.join(b)))
        .write_all_concatenated(&out, env!("CARGO_PKG_NAME"));
    let dest = manifest.join("../../apple/FLOWS/RustBridge");
    fs::create_dir_all(&dest).expect("create apple/FLOWS/RustBridge");
    copy_if_changed(&out, &dest).expect("copy generated bindings");
}
