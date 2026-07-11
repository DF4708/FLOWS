// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Compression
import XCTest

/// Gates for the ECCC/SMN provider parsing — field shapes verified against
/// live API probes (SWOB air_temp °C; SMN strings; SMN gzip file body).
final class IntlWeatherParsingTests: XCTestCase {

    func testECCCTemperatureExtraction() {
        // Live-verified shape: air_temp = 21.6 (°C)
        let f = IntlWeatherParsing.ecccAirTempF(["air_temp": 21.6])
        XCTAssertEqual(f!, 70.88, accuracy: 0.001)
        XCTAssertEqual(IntlWeatherParsing.ecccAirTempF(["air_temp": "0"])!, 32)
        XCTAssertNil(IntlWeatherParsing.ecccAirTempF(["unrelated": 1.0]))
    }

    func testECCCWindPrefersTenMeterSensorAndConvertsUnits() {
        let props: [String: Any] = [
            "avg_wnd_spd_pcpn_gag_pst10mts": 0.2, "avg_wnd_spd_pcpn_gag_pst10mts-uom": "m/s",
            "avg_wnd_spd_10m_pst2mts": 18.0, "avg_wnd_spd_10m_pst2mts-uom": "km/h",
        ]
        // 18 km/h ≈ 11.18 mph — the 10 m tower sensor must win.
        XCTAssertEqual(IntlWeatherParsing.ecccWindMph(props)!, 18 / 1.609344, accuracy: 0.001)
        // m/s conversion when it's the only sensor.
        let ms: [String: Any] = ["wnd_spd": 10.0, "wnd_spd-uom": "m/s"]
        XCTAssertEqual(IntlWeatherParsing.ecccWindMph(ms)!, 22.369, accuracy: 0.01)
    }

    func testSMNRowParsingAndConditions() {
        // Live-verified shape: SMN serves strings.
        let row = IntlWeatherParsing.smnRow([
            "lat": "25.6647", "lon": "-100.3109",
            "tmax": "34.4", "tmin": "19.0", "velvien": "7.7", "probprec": "50",
        ])!
        XCTAssertEqual(row.lat, 25.6647)
        let c = IntlWeatherParsing.conditions(from: row)
        // midpoint 26.7 °C → 80.06 °F
        XCTAssertEqual(c.temperatureF!, (34.4 + 19.0) / 2 * 9 / 5 + 32, accuracy: 0.001)
        XCTAssertEqual(c.windMph!, 7.7 / 1.609344, accuracy: 0.001)
        XCTAssertEqual(c.popPercent!, 50)
        XCTAssertNil(IntlWeatherParsing.smnRow(["tmax": "30"]))   // no coords
    }

    func testGunzipRoundTrip() {
        // Build a gzip container the way SMN serves one (FNAME flag set),
        // around a deflate stream from the Compression framework.
        let payload = Data(#"[{"nmun":"Monterrey","tmax":"34.4"}]"#.utf8)
        var deflated = Data(count: payload.count + 128)
        let written = deflated.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, payload.count + 128,
                    src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        deflated.removeSubrange(written..<deflated.count)
        var gz = Data([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0])   // FNAME flag
        gz.append(Data("x.json\0".utf8))
        gz.append(deflated)
        gz.append(Data([0, 0, 0, 0]))   // CRC (unchecked by our reader)
        var isize = UInt32(payload.count).littleEndian
        gz.append(Data(bytes: &isize, count: 4))

        let out = IntlWeatherParsing.gunzip(gz)
        XCTAssertEqual(out, payload)
        XCTAssertNil(IntlWeatherParsing.gunzip(Data([0, 1, 2, 3])))
    }
}
