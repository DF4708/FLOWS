// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! What a rider means by the ways of travelling they switched on.
//!
//! The Routes card has a Drive | Walk choice and five toggles — train, bus,
//! plane, rental car, ship — and a rider may switch on any mix of them. A mix is
//! one trip, not several: the owner's rule (2026-09-29) is that "car, bus and
//! train" means drive to the train and take the bus from the train at the far
//! end, and "walk, bus and plane" means walk to a bus that goes to the
//! airport and the same in reverse at the other end, unless a rental car is
//! also on, in which case the car is picked up where the plane lands.
//!
//! So a selection is read as one trip with three parts:
//!
//! * the **main ride** — the long way: a plane when flying is worth it, else
//!   a ship (a ferry, at any distance — the water decides, not the miles),
//!   else an intercity train, else an intercity bus; none on a short trip;
//! * the **way there** — the rider's own car (walk if the station is close,
//!   drive and park if not), on foot, or the city's buses and trains when the
//!   rider walks and chose them;
//! * the **way from** — a rental car when chosen, else the city's buses and
//!   trains when chosen, else on foot (or, from an airport, a ride or a
//!   rental — airports rarely end on foot).
//!
//! A short trip has no main ride: the city's buses and trains go door to
//! door, and a rental car on its own is picked up near the start.
//!
//! The ship (owner, 2026-09-30: "ferries and any other sea transport such as
//! cruises") is the main ride whenever it is on and a plane is not; the
//! chosen buses and trains then reach the terminal and leave the far one.
//! Beside a plane it becomes a city vehicle, so a ferry can carry an end.
//! When no sailing fits, the app plans the rest without it (as it does for
//! a plane with no flight) and the ship card says why.
//!
//! The rule is here, not in the view, so every combination is pinned by a
//! test and the Swift side only carries it out.

use crate::transit::{BUS_VEHICLES, SHIP_VEHICLES, TRAIN_VEHICLES};
use crate::travel_modes::worth_flying;

/// Past this, a train or bus toggle means the intercity service (Amtrak,
/// Greyhound); under it, the city's own buses and trains.
pub const LONG_HAUL_MILES: f64 = 60.0;

/// A walk longer than this (45 minutes) is not the way anyone reaches a
/// station: a driver drives and parks, a walker is offered a ride share.
pub const FAR_WALK_SECONDS: f64 = 2_700.0;

/// A city bus or train replaces a walk only when it gets there at least this
/// much sooner — five minutes, because a timetable can slip and a walk can't.
pub const TRANSIT_MUST_SAVE_SECONDS: f64 = 300.0;

/// A city vehicle the rider did not choose takes a leg from the one they did
/// only when it gets there this much sooner — fifteen minutes — or when the
/// chosen one cannot make the trip at all. "Walk, bus and plane" means the
/// city's transit to the airport; where the airport's link is a train
/// (Minneapolis's Blue Line), a bus-only answer went by way of St. Paul.
pub const OTHER_VEHICLE_MUST_SAVE_SECONDS: f64 = 900.0;

/// The toggles as the rider left them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Picked {
    /// Walk rather than Drive: the rider has no car of their own here.
    pub on_foot: bool,
    pub train: bool,
    pub bus: bool,
    pub plane: bool,
    pub rental: bool,
    /// Ferries, water taxis — and cruises, which the app can only point to.
    pub ship: bool,
}

/// The long way.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Main {
    /// A short trip: the city's own buses and trains, or a rental, go door
    /// to door.
    None = 0,
    Plane = 1,
    /// Intercity rail — Amtrak.
    Train = 2,
    /// Intercity bus — Greyhound.
    Coach = 3,
    /// A ferry across the water, from a terminal near the start to one near
    /// the destination.
    Ship = 4,
}

/// How the rider reaches the main ride.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Access {
    /// Their own car: walk when the station is close, drive and park when
    /// it is not.
    OwnCar = 0,
    /// On foot, with a ride share offered when the walk is long.
    OnFoot = 1,
    /// The city's buses or trains, when they beat walking; on foot when
    /// they do not.
    Local = 2,
}

/// How the rider gets from the main ride to where they are going.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Egress {
    Walk = 0,
    /// The city's buses or trains, when they beat walking.
    Local = 1,
    /// A rental car picked up where the main ride ends.
    Rental = 2,
    /// From an airport or a ferry terminal: walk when it is close, else a ride
    /// share (on foot) or a rental or a ride (with a car at home).
    RentOrRide = 3,
}

/// Which cards the Routes list shows for a selection (bits of [`Shape::cards`]).
/// The whole trip, main ride and both ends, on one card.
pub const CARD_MAIN: u8 = 1;
/// A short trip on the city's buses and trains, door to door.
pub const CARD_LOCAL: u8 = 2;
/// A short trip in a rental car picked up near the start.
pub const CARD_RENTAL: u8 = 4;
/// The plane was on but this trip is not one to fly — say why.
pub const CARD_PLANE_NOTE: u8 = 8;

/// One selection, read as one trip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shape {
    pub main: Main,
    pub access: Access,
    pub egress: Egress,
    /// What the far end becomes when the city has no timetable or its
    /// buses and trains do not beat walking.
    pub egress_fallback: Egress,
    /// The city vehicles the rider accepts, as [`crate::transit::Mode`]
    /// bits; 0 when they chose none.
    pub local_vehicles: u8,
    /// The cards to show, from the `CARD_` bits.
    pub cards: u8,
}

/// Read a selection as one trip of `trip_miles`.
#[must_use]
pub fn shape(p: Picked, trip_miles: f64) -> Shape {
    let long = trip_miles > LONG_HAUL_MILES;
    let main = if p.plane && worth_flying(trip_miles) {
        Main::Plane
    } else if p.ship {
        Main::Ship
    } else if long && p.train {
        Main::Train
    } else if long && p.bus {
        Main::Coach
    } else {
        Main::None
    };

    // A rider who chose the train will take the city's trains too, and one
    // who chose the bus its buses — the choice is the vehicle, not the
    // operator. A ship that is not the main ride (a plane is) may carry an
    // end, the ferry to the island the airport serves.
    let local_vehicles = if p.train { TRAIN_VEHICLES } else { 0 }
        | if p.bus { BUS_VEHICLES } else { 0 }
        | if p.ship && main != Main::Ship {
            SHIP_VEHICLES
        } else {
            0
        };

    let access = if !p.on_foot {
        // With a car at the start, the car is how they reach the main ride —
        // "car, bus and train" drives to the train.
        Access::OwnCar
    } else if main != Main::None && local_vehicles != 0 {
        Access::Local
    } else {
        Access::OnFoot
    };

    // Airports and ferry terminals both sit where the rider rarely ends up.
    let egress_fallback = if matches!(main, Main::Plane | Main::Ship) {
        Egress::RentOrRide
    } else {
        Egress::Walk
    };
    let egress = if main == Main::None {
        egress_fallback
    } else if p.rental {
        Egress::Rental
    } else if local_vehicles != 0 {
        Egress::Local
    } else {
        egress_fallback
    };

    let mut cards = 0;
    if main != Main::None {
        cards |= CARD_MAIN;
    } else {
        if local_vehicles != 0 {
            cards |= CARD_LOCAL;
        }
        if p.rental {
            cards |= CARD_RENTAL;
        }
    }
    if p.plane && main != Main::Plane {
        cards |= CARD_PLANE_NOTE;
    }

    Shape {
        main,
        access,
        egress,
        egress_fallback,
        local_vehicles,
        cards,
    }
}

/// Whether a city bus or train should replace a walk: it must get there at
/// least [`TRANSIT_MUST_SAVE_SECONDS`] sooner, counting the wait. A walk that
/// could not be measured loses to any ride that exists.
#[must_use]
pub fn transit_beats_walk(walk_seconds: Option<f64>, transit_seconds: f64) -> bool {
    if !transit_seconds.is_finite() || transit_seconds < 0.0 {
        return false;
    }
    match walk_seconds {
        Some(w) if w.is_finite() => transit_seconds + TRANSIT_MUST_SAVE_SECONDS <= w,
        _ => true,
    }
}

/// Whether a city trip on any vehicle should replace the trip on the ones the
/// rider chose — see [`OTHER_VEHICLE_MUST_SAVE_SECONDS`]. No chosen trip at
/// all loses to any trip that exists.
#[must_use]
pub fn other_vehicle_wins(chosen_seconds: Option<f64>, other_seconds: f64) -> bool {
    if !other_seconds.is_finite() || other_seconds < 0.0 {
        return false;
    }
    match chosen_seconds {
        Some(c) if c.is_finite() => other_seconds + OTHER_VEHICLE_MUST_SAVE_SECONDS <= c,
        _ => true,
    }
}

/// A shape as one integer for the Swift boundary: a byte each for main,
/// access, egress, fallback, city vehicles and cards, lowest first.
#[must_use]
pub fn pack(s: Shape) -> i64 {
    i64::from(s.main as u8)
        | i64::from(s.access as u8) << 8
        | i64::from(s.egress as u8) << 16
        | i64::from(s.egress_fallback as u8) << 24
        | i64::from(s.local_vehicles) << 32
        | i64::from(s.cards) << 40
}

#[cfg(test)]
mod tests {
    use super::*;

    const LONG: f64 = 400.0; // worth flying, and intercity
    const MIDDLE: f64 = 80.0; // intercity, not worth flying
    const SHORT: f64 = 12.0;

    fn pick(on_foot: bool, train: bool, bus: bool, plane: bool, rental: bool) -> Picked {
        Picked {
            on_foot,
            train,
            bus,
            plane,
            rental,
            ship: false,
        }
    }

    fn and_ship(mut p: Picked) -> Picked {
        p.ship = true;
        p
    }

    #[test]
    fn car_bus_and_train_drives_to_the_train_and_takes_the_bus_from_it() {
        // The owner's first example.
        let s = shape(pick(false, true, true, false, false), LONG);
        assert_eq!(s.main, Main::Train);
        assert_eq!(s.access, Access::OwnCar);
        assert_eq!(s.egress, Egress::Local);
        assert_eq!(s.local_vehicles & BUS_VEHICLES, BUS_VEHICLES);
        assert_eq!(
            s.cards, CARD_MAIN,
            "one trip, one card — no separate bus card"
        );
    }

    #[test]
    fn walk_bus_and_plane_rides_the_bus_to_the_airport_and_from_it() {
        // The owner's second example.
        let s = shape(pick(true, false, true, true, false), LONG);
        assert_eq!(s.main, Main::Plane);
        assert_eq!(s.access, Access::Local);
        assert_eq!(s.egress, Egress::Local);
        assert_eq!(s.egress_fallback, Egress::RentOrRide);
        assert_eq!(s.local_vehicles, BUS_VEHICLES, "the bus, not the subway");
        assert_eq!(s.cards, CARD_MAIN);
    }

    #[test]
    fn a_rental_replaces_the_bus_at_the_far_end_but_not_the_way_there() {
        // "…unless they also chose the rental car option."
        let s = shape(pick(true, false, true, true, true), LONG);
        assert_eq!(s.main, Main::Plane);
        assert_eq!(s.access, Access::Local);
        assert_eq!(s.egress, Egress::Rental);
        assert_eq!(s.cards, CARD_MAIN);

        let s = shape(pick(false, true, true, false, true), LONG);
        assert_eq!(
            (s.main, s.access, s.egress),
            (Main::Train, Access::OwnCar, Egress::Rental)
        );
    }

    #[test]
    fn one_toggle_alone_keeps_the_cards_it_always_had() {
        let train = shape(pick(false, true, false, false, false), LONG);
        assert_eq!((train.main, train.access), (Main::Train, Access::OwnCar));
        assert_eq!(
            train.egress,
            Egress::Local,
            "a train rider takes the city's trains"
        );
        assert_eq!(train.local_vehicles, TRAIN_VEHICLES);

        let bus = shape(pick(true, false, true, false, false), LONG);
        assert_eq!(
            (bus.main, bus.access, bus.egress),
            (Main::Coach, Access::Local, Egress::Local)
        );

        let plane = shape(pick(false, false, false, true, false), LONG);
        assert_eq!(plane.main, Main::Plane);
        assert_eq!(plane.access, Access::OwnCar);
        assert_eq!(
            plane.egress,
            Egress::RentOrRide,
            "airports rarely end on foot"
        );
        assert_eq!(plane.local_vehicles, 0);

        let walker = shape(pick(true, false, false, true, false), LONG);
        assert_eq!(walker.access, Access::OnFoot, "no city vehicles chosen");
    }

    #[test]
    fn the_plane_wins_the_main_ride_only_when_flying_is_worth_it() {
        let s = shape(pick(false, true, false, true, false), MIDDLE);
        assert_eq!(s.main, Main::Train, "80 miles: the train, not a flight");
        assert_eq!(
            s.cards,
            CARD_MAIN | CARD_PLANE_NOTE,
            "and the plane says why"
        );

        let s = shape(pick(false, true, false, true, false), LONG);
        assert_eq!(s.main, Main::Plane);
        assert_eq!(
            s.egress,
            Egress::Local,
            "the train is the city train from the airport"
        );
        assert_eq!(s.cards, CARD_MAIN);
    }

    #[test]
    fn a_short_trip_goes_door_to_door_on_the_city() {
        let s = shape(pick(true, true, true, false, false), SHORT);
        assert_eq!(s.main, Main::None);
        assert_eq!(s.cards, CARD_LOCAL);
        assert_eq!(s.local_vehicles, TRAIN_VEHICLES | BUS_VEHICLES);

        let s = shape(pick(true, false, false, false, true), SHORT);
        assert_eq!(
            s.cards, CARD_RENTAL,
            "a rental alone is picked up near the start"
        );

        let s = shape(pick(false, false, true, true, true), SHORT);
        assert_eq!(s.cards, CARD_LOCAL | CARD_RENTAL | CARD_PLANE_NOTE);
    }

    #[test]
    fn a_long_trip_with_only_a_rental_rents_near_the_start() {
        let s = shape(pick(true, false, false, false, true), LONG);
        assert_eq!(s.main, Main::None);
        assert_eq!(s.cards, CARD_RENTAL);
    }

    #[test]
    fn nothing_on_shows_nothing() {
        assert_eq!(shape(Picked::default(), LONG).cards, 0);
        assert_eq!(
            shape(pick(true, false, false, false, false), SHORT).cards,
            0
        );
    }

    #[test]
    fn every_selection_shows_at_least_one_card_and_never_two_main_rides() {
        for bits in 1u8..64 {
            let mut p = pick(
                bits & 1 != 0,
                bits & 2 != 0,
                bits & 4 != 0,
                bits & 8 != 0,
                bits & 16 != 0,
            );
            p.ship = bits & 32 != 0;
            for miles in [SHORT, MIDDLE, LONG] {
                let s = shape(p, miles);
                let any_mode = p.train || p.bus || p.plane || p.rental || p.ship;
                assert_eq!(s.cards != 0, any_mode, "{p:?} at {miles} mi");
                if s.cards & CARD_MAIN != 0 {
                    assert_eq!(s.cards & (CARD_LOCAL | CARD_RENTAL), 0, "{p:?}");
                }
                if !p.on_foot {
                    assert_eq!(s.access, Access::OwnCar, "{p:?}");
                }
                if p.rental && s.main != Main::None {
                    assert_eq!(s.egress, Egress::Rental, "{p:?}");
                }
                if p.ship {
                    // Always part of the trip: the ride itself, or beside a
                    // plane a ferry at an end — never boarded unless chosen.
                    assert!(
                        s.main == Main::Ship || s.local_vehicles & SHIP_VEHICLES != 0,
                        "{p:?} at {miles} mi"
                    );
                } else {
                    assert_eq!(s.local_vehicles & SHIP_VEHICLES, 0, "{p:?}");
                    assert_ne!(s.main, Main::Ship, "{p:?}");
                }
            }
        }
    }

    #[test]
    fn a_ship_is_the_ride_at_any_distance() {
        // A ferry is the way across the water whether it is two miles (the
        // Staten Island Ferry) or two hundred (the Alaska Marine Highway).
        for miles in [SHORT, MIDDLE, LONG] {
            let s = shape(and_ship(pick(false, false, false, false, false)), miles);
            assert_eq!(s.main, Main::Ship, "{miles} mi");
            assert_eq!(s.access, Access::OwnCar);
            assert_eq!(s.egress, Egress::RentOrRide, "terminals rarely end a trip");
            assert_eq!(
                s.local_vehicles, 0,
                "the ship is the ride, not a city vehicle"
            );
            assert_eq!(s.cards, CARD_MAIN);
        }
    }

    #[test]
    fn walk_bus_and_ship_rides_the_bus_to_the_ferry_and_from_it() {
        // The owner's walk-bus-plane pattern, across water.
        let s = shape(and_ship(pick(true, false, true, false, false)), SHORT);
        assert_eq!(s.main, Main::Ship);
        assert_eq!(s.access, Access::Local);
        assert_eq!(s.egress, Egress::Local);
        assert_eq!(s.local_vehicles, BUS_VEHICLES);
        assert_eq!(s.cards, CARD_MAIN, "one trip: no separate city card");

        let s = shape(and_ship(pick(false, true, false, false, true)), MIDDLE);
        assert_eq!(
            (s.main, s.access, s.egress),
            (Main::Ship, Access::OwnCar, Egress::Rental),
            "a rental waits at the far terminal"
        );
    }

    #[test]
    fn beside_a_flight_the_ship_carries_an_end() {
        let s = shape(and_ship(pick(true, false, false, true, false)), LONG);
        assert_eq!(s.main, Main::Plane);
        assert_eq!(s.local_vehicles, SHIP_VEHICLES);
        assert_eq!(s.access, Access::Local, "a ferry to the airport");

        // Too short to fly: the plane leaves a note and the ship sails.
        let s = shape(and_ship(pick(false, false, false, true, false)), MIDDLE);
        assert_eq!(s.main, Main::Ship);
        assert_eq!(s.cards, CARD_MAIN | CARD_PLANE_NOTE);
    }

    #[test]
    fn a_city_ride_must_save_five_minutes_to_replace_a_walk() {
        assert!(transit_beats_walk(Some(1_800.0), 1_200.0));
        assert!(
            transit_beats_walk(Some(1_500.0), 1_200.0),
            "exactly five minutes"
        );
        assert!(!transit_beats_walk(Some(1_400.0), 1_200.0));
        assert!(
            transit_beats_walk(None, 7_200.0),
            "an unmeasured walk loses"
        );
        assert!(!transit_beats_walk(Some(600.0), f64::NAN));
        assert!(!transit_beats_walk(None, -1.0));
    }

    #[test]
    fn another_city_vehicle_must_save_fifteen_minutes() {
        assert!(
            other_vehicle_wins(None, 3_000.0),
            "the bus cannot make the trip"
        );
        assert!(
            other_vehicle_wins(Some(4_000.0), 3_000.0),
            "the St. Paul detour loses"
        );
        assert!(
            other_vehicle_wins(Some(3_900.0), 3_000.0),
            "exactly fifteen minutes"
        );
        assert!(
            !other_vehicle_wins(Some(3_800.0), 3_000.0),
            "close enough: the rider's choice"
        );
        assert!(!other_vehicle_wins(Some(3_000.0), f64::INFINITY));
        assert!(!other_vehicle_wins(None, -5.0));
    }

    #[test]
    fn a_shape_packs_one_byte_per_part() {
        let s = shape(pick(true, false, true, true, true), LONG);
        let v = pack(s);
        assert_eq!(v & 0xFF, Main::Plane as i64);
        assert_eq!(v >> 8 & 0xFF, Access::Local as i64);
        assert_eq!(v >> 16 & 0xFF, Egress::Rental as i64);
        assert_eq!(v >> 24 & 0xFF, Egress::RentOrRide as i64);
        assert_eq!(v >> 32 & 0xFF, i64::from(BUS_VEHICLES));
        assert_eq!(v >> 40 & 0xFF, i64::from(CARD_MAIN));
    }
}
