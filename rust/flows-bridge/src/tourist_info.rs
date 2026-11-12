// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::tourist_info`, behind Swift's
//! `TouristInfo`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - Names arrive cleaned by Swift (`TouristInfo.normalized`).
//! - The fee table's keys cross joined by their UTF-8 lengths with their
//!   count; the answer is the index of the chosen key, or `-1` for a park
//!   the table does not name, `-2` for another national site, `-3` for
//!   anything else. A count the lengths do not hold, or a panic inside,
//!   answers `-3` ("prices vary", never a made-up fee).
//! - The kind comes back as `tourist_info::Kind`'s number; a panic answers
//!   a place worth a stop (14).

use crate::{contain, split_texts};
use flows_core::tourist_info as ti;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_tourist_fee(name: &str, keys_joined: &str, key_lens: &[i64], count: i64) -> i64;
        fn flows_tourist_kind(name: &str, category: &str, has_category: bool) -> i64;
        fn flows_tourist_monday_first_index(weekday: i64) -> i64;
    }
}

const PARK_DEFAULT: i64 = -1;
const SITE_DEFAULT: i64 = -2;
const VARIES: i64 = -3;

pub fn flows_tourist_fee(name: &str, keys_joined: &str, key_lens: &[i64], count: i64) -> i64 {
    contain(VARIES, || {
        let Some(keys) = usize::try_from(count)
            .ok()
            .and_then(|n| split_texts(keys_joined, key_lens, n))
        else {
            return VARIES;
        };
        match ti::fee(name, &keys) {
            ti::Fee::Table(i) => i64::try_from(i).unwrap_or(VARIES),
            ti::Fee::ParkDefault => PARK_DEFAULT,
            ti::Fee::SiteDefault => SITE_DEFAULT,
            ti::Fee::Varies => VARIES,
        }
    })
}

pub fn flows_tourist_kind(name: &str, category: &str, has_category: bool) -> i64 {
    contain(ti::Kind::WorthAStop as i64, || {
        ti::kind(name, has_category.then_some(category)) as i64
    })
}

pub fn flows_tourist_monday_first_index(weekday: i64) -> i64 {
    ti::monday_first_index(weekday)
}
