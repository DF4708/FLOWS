// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// ECCC's `weather-alerts` records (MSC GeoMet), the shape the Canadian
/// feed has had since its old `alerts` collection started answering 404:
/// until then Canada had no weather alerts at all.
final class CanadianAlertsTests: XCTestCase {
    /// A live record from 2026-09-21, geometry trimmed to one small ring.
    private let frost = """
    {"id":"132605352802317227202609200503_fea1-1234","type":"Feature",
     "geometry":{"type":"MultiPolygon","coordinates":[[[[-78.51,44.50],[-78.42,44.49],
       [-78.42,44.60],[-78.51,44.60],[-78.51,44.50]]]]},
     "properties":{"alert_code":"FTA","alert_type":"advisory",
       "alert_name_en":"frost advisory","alert_short_name_en":"Frost (advisory)",
       "publication_datetime":"2026-09-21T16:50:44.658Z",
       "expiration_datetime":"2026-09-22T08:50:44.658Z",
       "validity_datetime":"2026-09-22T07:00:00.000Z",
       "event_end_datetime":"2026-09-22T13:30:00.000Z",
       "alert_text_en":"Conditions are favourable for the development of frost tonight.",
       "risk_colour_en":"yellow","confidence_en":"High","impact_en":"Moderate",
       "feature_name_en":"Apsley - Woodview - Northern Peterborough County",
       "province":"ON","status_en":"continued","feature_id":"fea1-1234"}}
    """

    private func feature(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheNewRecordShapeParses() throws {
        let alerts = WeatherAlertService.parseECCCFeatures([try feature(frost)])
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alert.id, "132605352802317227202609200503_fea1-1234")
        XCTAssertEqual(alert.event, "Frost Advisory")
        XCTAssertEqual(alert.headline,
                       "Frost Advisory for Apsley - Woodview - Northern Peterborough County")
        XCTAssertEqual(alert.severityScore, WeatherAlertService.severityScore("moderate"))
        // Milliseconds in every timestamp: the plain parser returned nil.
        XCTAssertEqual(alert.expires, WeatherAlertService.ecccDate("2026-09-22T08:50:44.658Z"))
        XCTAssertNotNil(alert.expires)
        XCTAssertEqual(alert.onset, WeatherAlertService.ecccDate("2026-09-22T07:00:00.000Z"))
        XCTAssertEqual(alert.detail,
                       "Conditions are favourable for the development of frost tonight.")
        XCTAssertEqual(alert.polygon?.count, 5)
    }

    func testEndedAndCancelledAlertsAreDropped() throws {
        for status in ["ended", "cancelled", "Ended"] {
            let json = frost.replacingOccurrences(of: "\"continued\"", with: "\"\(status)\"")
            XCTAssertTrue(WeatherAlertService.parseECCCFeatures([try feature(json)]).isEmpty, status)
        }
    }

    func testRiskColourIsTheSeverity() {
        XCTAssertEqual(WeatherAlertService.ecccSeverity(colour: "red", type: "advisory"), "extreme")
        XCTAssertEqual(WeatherAlertService.ecccSeverity(colour: "Orange", type: nil), "severe")
        XCTAssertEqual(WeatherAlertService.ecccSeverity(colour: "yellow", type: "warning"), "moderate")
        // Without a colour, the kind of alert decides.
        XCTAssertEqual(WeatherAlertService.ecccSeverity(colour: nil, type: "warning"), "severe")
        XCTAssertEqual(WeatherAlertService.ecccSeverity(colour: nil, type: "watch"), "moderate")
        XCTAssertEqual(WeatherAlertService.ecccSeverity(colour: nil, type: "statement"), "minor")
    }

    func testTimesWithAndWithoutMilliseconds() {
        XCTAssertNotNil(WeatherAlertService.ecccDate("2026-09-22T08:50:44.658Z"))
        XCTAssertNotNil(WeatherAlertService.ecccDate("2026-09-22T08:50:44Z"))
        XCTAssertNil(WeatherAlertService.ecccDate("not a time"))
    }
}
