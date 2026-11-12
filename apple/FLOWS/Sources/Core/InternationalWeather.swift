// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Compression
import CoreLocation
import FlowsBridge
import Foundation

/// Pure parsing/conversion helpers for the international weather providers —
/// separated for unit testing (the network side lives in NWSForecastFetcher's
/// provider chain). The rules run in Rust (flows-core `intl_weather`, pinned
/// by a frozen oracle of this file's original rules); Swift reads each JSON
/// field as a number its own way and hands the numbers over. The gzip body
/// and the SMN row stay here.
enum IntlWeatherParsing {

    // MARK: unit conversions

    static func celsiusToF(_ c: Double) -> Double { flows_intl_celsius_to_f(c) }
    static func kmhToMph(_ kmh: Double) -> Double { flows_intl_kmh_to_mph(kmh) }
    static func msToMph(_ ms: Double) -> Double { flows_intl_ms_to_mph(ms) }

    /// A field read as a number: a JSON number, or text that reads as one.
    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? String).flatMap(Double.init)
    }

    /// A Rust `[has, value]` answer.
    private static func reading(_ answer: [Double]) -> Double? {
        answer.count == 2 && answer[0] != 0 ? answer[1] : nil
    }

    // MARK: ECCC SWOB observation extraction

    /// Scan a SWOB properties dict for air temperature (°C) — the field is
    /// reliably `air_temp` but station variants exist.
    static func ecccAirTempF(_ props: [String: Any]) -> Double? {
        let numbers = ["air_temp", "air_temp_1", "avg_air_temp_pst1hr"].map { number(props[$0]) }
        let values = numbers.map { $0 ?? 0 }
        let present = numbers.map { UInt8($0 == nil ? 0 : 1) }
        return reading(
            values.lent { v in
                present.lent { p in Array(flows_intl_air_temp_f(v, p, Int64(numbers.count))) }
            })
    }

    /// Wind speed in mph from whichever anemometer field the station has;
    /// prefers 10 m sensors, converts by the sibling `-uom` unit (km/h vs m/s).
    /// Each field crosses with its NFC name (Rust orders the names by their
    /// bytes), its value read as a number, and its `-uom` text, looked up
    /// here as the dictionary answers it.
    static func ecccWindMph(_ props: [String: Any]) -> Double? {
        guard !props.isEmpty else { return nil }
        let keys = Array(props.keys)
        let speeds = keys.map { number(props[$0]) }
        let names = RustTextColumn(keys.map { $0.precomposedStringWithCanonicalMapping })
        let units = RustTextColumn(keys.map { props["\($0)-uom"] as? String })
        let values = speeds.map { $0 ?? 0 }
        let present = speeds.map { UInt8($0 == nil ? 0 : 1) }
        return reading(
            names.with { nj, nl, _ in
                units.with { uj, ul, up in
                    values.lent { v in
                        present.lent { p in
                            Array(flows_intl_wind_mph(nj, nl, v, p, uj, ul, up, Int64(keys.count)))
                        }
                    }
                }
            })
    }

    // MARK: SMN municipio rows

    struct SMNRow {
        let lat: Double
        let lon: Double
        let tmaxC: Double?
        let tminC: Double?
        let windKmh: Double?
        let popPct: Double?
    }

    /// SMN serves strings; parse defensively.
    static func smnRow(_ dict: [String: Any]) -> SMNRow? {
        func num(_ key: String) -> Double? {
            (dict[key] as? Double) ?? (dict[key] as? String).flatMap(Double.init)
        }
        guard let lat = num("lat"), let lon = num("lon") else { return nil }
        return SMNRow(
            lat: lat, lon: lon, tmaxC: num("tmax"), tminC: num("tmin"),
            windKmh: num("velvien"), popPct: num("probprec"))
    }

    /// Daily row → current-conditions approximation: midpoint temperature
    /// (SMN method=1 is a daily municipal forecast, not hourly — documented).
    static func conditions(from row: SMNRow) -> ForecastConditions {
        var c = ForecastConditions()
        let n = Array(
            flows_intl_smn_conditions(
                row.tmaxC ?? 0, row.tmaxC != nil, row.tminC ?? 0, row.tminC != nil, row.windKmh ?? 0,
                row.windKmh != nil))
        if n.count == 4 {
            c.temperatureF = reading(Array(n[0..<2]))
            c.windMph = reading(Array(n[2..<4]))
        }
        c.popPercent = row.popPct
        return c
    }

    // MARK: gzip (SMN serves a gzip FILE body, not transport encoding)

    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else { return nil }
        let flags = data[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {  // FNAME — null-terminated
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset < data.count - 8 else { return nil }
        let deflated = data.subdata(in: offset..<(data.count - 8))

        // ISIZE trailer: uncompressed size mod 2^32 — sizes our buffer.
        // Low byte first, read by hand: no raw memory is touched.
        let isize = data.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Capped: the trailer is the server's word, and a bad one asked for
        // up to 4 GB. A decode that fills the buffer stopped at its end —
        // truncated, unless the trailer names exactly that size — and is
        // refused (it was returned as the whole file).
        let capacity = min(max(Int(isize), deflated.count * 4, 64_000), 16 << 20)
        guard let out = RawBytes.inflate(deflated, capacity: capacity),
            out.count < capacity || out.count == Int(isize)
        else { return nil }
        return out
    }
}
