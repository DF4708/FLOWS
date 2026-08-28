// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// Turning transcribed dispatch traffic into map pins — and, more
/// importantly, refusing to when the words don't support one.
final class ScannerIncidentTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 33.53, longitude: -82.12)

    private func at(_ dLat: Double, _ dLon: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: here.latitude + dLat,
                               longitude: here.longitude + dLon)
    }

    private func incident(_ kind: ScannerIncidents.Kind,
                          _ c: CLLocationCoordinate2D,
                          age: TimeInterval = 0,
                          id: String = "x") -> ScannerIncidents.Incident {
        ScannerIncidents.Incident(id: id, kind: kind, coordinate: c,
                                  placeText: "somewhere",
                                  heardAt: Date().addingTimeInterval(-age))
    }

    // MARK: what kind of call is it

    func testCommonCallsAreRecognized() {
        let cases: [(String, ScannerIncidents.Kind)] = [
            ("Engine 3 responding to a structure fire", .fire),
            ("Medic 12 en route, patient in cardiac arrest", .medical),
            ("Units responding, shots fired at the plaza", .police),
            ("Motor vehicle accident with injury on the bypass", .traffic),
            ("Rescue squad for a water rescue at the creek", .rescue),
            ("Hazmat response, gas leak reported", .hazard),
        ]
        for (text, want) in cases {
            XCTAssertEqual(ScannerIncidents.kind(inTranscript: text), want, text)
        }
    }

    func testTheSpecificCallBeatsTheGeneralOne() {
        // "Motor vehicle accident with injury" is a crash, not a medical —
        // and units responding to a structure fire is a fire, not police.
        XCTAssertEqual(
            ScannerIncidents.kind(inTranscript:
                "motor vehicle accident with injury, medic responding"), .traffic)
        XCTAssertEqual(
            ScannerIncidents.kind(inTranscript:
                "units responding to a working fire, officer on scene"), .fire)
    }

    func testChatterWithNoRecognizableCallIsDropped() {
        // Silence beats a guess: a wrong red pin is worse than no pin.
        XCTAssertNil(ScannerIncidents.kind(inTranscript: "radio check, loud and clear"))
        XCTAssertNil(ScannerIncidents.kind(inTranscript: ""))
        XCTAssertNil(ScannerIncidents.kind(inTranscript: "clear from the last call"))
    }

    func testEveryKindIsReachableThroughItsOwnWords() {
        for kind in ScannerIncidents.Kind.allCases {
            let phrase = kind.phrases.first ?? ""
            XCTAssertEqual(ScannerIncidents.kind(inTranscript: phrase), kind,
                           "\(kind.rawValue) unreachable via '\(phrase)'")
        }
    }

    // MARK: where is it

    func testAStreetAddressIsPulledOut() {
        let place = ScannerIncidents.placePhrase(
            inTranscript: "respond to 2100 Washington Road for the alarm")
        XCTAssertEqual(place, "2100 washington road")
    }

    func testACrossStreetPairIsPulledOut() {
        let place = ScannerIncidents.placePhrase(
            inTranscript: "accident at Belair Road and Columbia Road")
        XCTAssertNotNil(place)
        XCTAssertTrue(place?.contains("and") ?? false, place ?? "nil")
    }

    func testAVagueLocationIsRefused() {
        // A unit number, a beat code, a nickname — none of these is
        // something the app can put a pin on, so nothing is drawn.
        XCTAssertNil(ScannerIncidents.placePhrase(inTranscript: "unit 42 responding"))
        XCTAssertNil(ScannerIncidents.placePhrase(inTranscript: "en route to the north end"))
        XCTAssertNil(ScannerIncidents.placePhrase(inTranscript: "signal 10 in progress"))
    }

    func testABareNumberIsNotAnAddress() {
        // "Engine 3" and "channel 2" have numbers but no road, so there is
        // nothing to geocode.
        XCTAssertNil(ScannerIncidents.placePhrase(inTranscript: "engine 3 responding"))
    }

    // MARK: how long a pin lives

    func testAPinExpiresOnItsOwn() {
        let old = incident(.police, here, age: ScannerIncidents.lifetime(for: .police) + 1)
        XCTAssertTrue(ScannerIncidents.isExpired(old))
        XCTAssertFalse(ScannerIncidents.isExpired(incident(.police, here)))
    }

    func testAShortLivedCallFadesBeforeALongOne() {
        // A traffic stop is over in minutes; a stale police pin is a lie
        // about where the police are. A hazard blocks a road far longer.
        XCTAssertLessThan(ScannerIncidents.lifetime(for: .police),
                          ScannerIncidents.lifetime(for: .hazard))
        XCTAssertLessThan(ScannerIncidents.lifetime(for: .medical),
                          ScannerIncidents.lifetime(for: .fire))
    }

    // MARK: what gets drawn

    func testOnlyNearbyCallsAreShown() {
        let far = incident(.fire, at(3.0), id: "far")     // ~330 km away
        let near = incident(.fire, at(0.05), id: "near")  // ~5 km away
        let shown = ScannerIncidents.visible([far, near], near: here)
        XCTAssertEqual(shown.map(\.id), ["near"])
    }

    func testACallOnTheROUTEIsShownEvenWhenItIsNotNearYouYet() {
        // The point of the corridor: something ahead on your road matters
        // before you are anywhere near it.
        let ahead = incident(.traffic, at(2.0), id: "ahead")
        let shown = ScannerIncidents.visible([ahead], near: here,
                                             corridor: [at(2.0)])
        XCTAssertEqual(shown.map(\.id), ["ahead"])
    }

    func testExpiredCallsAreNeverShownEvenIfClose() {
        let stale = incident(.police, here,
                             age: ScannerIncidents.lifetime(for: .police) + 60)
        XCTAssertTrue(ScannerIncidents.visible([stale], near: here).isEmpty)
    }

    // MARK: dispatch repeats itself

    func testTheSameCallReadOutTwiceIsOnePin() {
        // Dispatch repeats a call to several units; without merging, one
        // crash becomes a cluster of pins on one corner.
        let first = incident(.traffic, here, id: "first")
        let repeated = incident(.traffic, at(0.0005), id: "second")   // ~55 m
        let merged = ScannerIncidents.merged([first], adding: repeated)
        XCTAssertEqual(merged.map(\.id), ["second"])
    }

    func testTwoDIFFERENTKindsAtOneCornerBothStand() {
        // A crash and a fire at the same intersection are two things.
        let crash = incident(.traffic, here, id: "crash")
        let fire = incident(.fire, here, id: "fire")
        let merged = ScannerIncidents.merged([crash], adding: fire)
        XCTAssertEqual(Set(merged.map(\.id)), ["crash", "fire"])
    }

    func testTwoCallsOfAKindFarApartBothStand() {
        let a = incident(.fire, here, id: "a")
        let b = incident(.fire, at(0.05), id: "b")   // ~5 km
        XCTAssertEqual(ScannerIncidents.merged([a], adding: b).count, 2)
    }

    // MARK: the pins say what they are

    func testEveryKindHasItsOwnLookAndWords() {
        let kinds = ScannerIncidents.Kind.allCases
        XCTAssertEqual(Set(kinds.map(\.title)).count, kinds.count)
        XCTAssertEqual(Set(kinds.map(\.symbol)).count, kinds.count)
        // Police blue, medical red, fire orange — as asked for.
        XCTAssertEqual(ScannerIncidents.Kind.police.colorName, "blue")
        XCTAssertEqual(ScannerIncidents.Kind.medical.colorName, "red")
        XCTAssertEqual(ScannerIncidents.Kind.fire.colorName, "orange")
    }
}

/// Which hazard gets to NAME an area on the map.
final class HazardDominanceTests: XCTestCase {

    func testTheWorstHazardNamesTheArea() {
        // The reported bug: a Georgia ZIP surrounded by severe storms and
        // flooding came out labelled FIRE, because "fire" sat in a priority
        // tier that took the icon at 0.45 while storms and flooding were not
        // on the list at all and could never win.
        let families = ["fire": 0.50, "convective": 0.88, "qpf_flood": 0.72]
        XCTAssertEqual(HazardRanking.dominantFamily(families), "convective")
    }

    func testTheSameBugAppliedToEveryHazardOnThatList() {
        // Not just fire — any of the old "acute" families outranked a worse
        // storm. Each must now lose to it.
        for acute in ["air", "radiation", "tropical", "seismic", "avalanche"] {
            let families = [acute: 0.50, "convective": 0.90]
            XCTAssertEqual(HazardRanking.dominantFamily(families), "convective", acute)
        }
    }

    func testFloodingCanNameAnAreaNow() {
        XCTAssertEqual(HazardRanking.dominantFamily(["qpf_flood": 0.8, "fire": 0.5]),
                       "qpf_flood")
    }

    func testFireStillWinsWhenFireIsActuallyTheWorstThing() {
        XCTAssertEqual(HazardRanking.dominantFamily(["fire": 0.92, "convective": 0.55]),
                       "fire")
    }

    func testAnAcuteHazardWinsATIEButNotAGap() {
        // A distinct named danger is the more useful label when the numbers
        // are level — but a nudge, never a veto.
        XCTAssertEqual(HazardRanking.dominantFamily(["fire": 0.70, "convective": 0.70]),
                       "fire")
        XCTAssertEqual(HazardRanking.dominantFamily(["fire": 0.70, "convective": 0.80]),
                       "convective")
    }

    func testAQuietAreaIsNotNamedAtAll() {
        // Below the floor nothing is elevated enough to label, and the
        // forecast-dominant kind takes over instead.
        XCTAssertNil(HazardRanking.dominantFamily(["fire": 0.2, "convective": 0.3]))
        XCTAssertNil(HazardRanking.dominantFamily([:]))
    }

    func testEveryFamilyCanWinWhenItIsTheWorst() {
        // No family may be structurally excluded from naming an area — that
        // exclusion is what this whole fix was about.
        let families = ["fire", "convective", "qpf_flood", "winter", "wind",
                        "heat", "cold", "air", "radiation", "seismic",
                        "tropical", "volcanic", "avalanche", "tsunami"]
        for f in families {
            var scores = Dictionary(uniqueKeysWithValues:
                families.map { ($0, 0.5) })
            scores[f] = 0.99
            XCTAssertEqual(HazardRanking.dominantFamily(scores), f, f)
        }
    }
}

/// What a suggestion row actually plans against.
final class DestinationSuggestionTests: XCTestCase {

    private func suggestion(_ title: String, _ subtitle: String,
                            _ kind: DestinationSearch.Suggestion.Kind)
        -> DestinationSearch.Suggestion {
        DestinationSearch.Suggestion(title: title, subtitle: subtitle, kind: kind)
    }

    func testACompletionFoldsItsLocalityIntoTheQuery() {
        // "Publix Super Market, Augusta, GA" is a better query than the name
        // alone — that subtitle really is locality context.
        XCTAssertEqual(
            suggestion("Publix Super Market", "Augusta, GA", .completion).searchText,
            "Publix Super Market, Augusta, GA")
    }

    func testARecentDoesNotPlanAgainstItsOwnBadge() {
        // The bug: a recent's subtitle is the word "Recent", so the query
        // became "Sun Prairie, Recent" — which geocodes to nothing, and the
        // driver got "couldn't find that place" for a town they visit
        // every week.
        XCTAssertEqual(suggestion("Sun Prairie", "Recent", .recent).searchText,
                       "Sun Prairie")
    }

    func testAPredictionDoesNotPlanAgainstItsReason() {
        XCTAssertEqual(
            suggestion("Home", "where you usually go at this hour", .predicted)
                .searchText, "Home")
    }

    func testACoordinateRowDoesNotPlanAgainstItsLabel() {
        XCTAssertEqual(
            suggestion("43.0731, -89.4012", "Exact map point", .coordinate)
                .searchText, "43.0731, -89.4012")
    }

    func testATitleOnlyRowIsUnchanged() {
        XCTAssertEqual(suggestion("Madison", "", .completion).searchText, "Madison")
    }
}
