// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Compression
import CoreLocation
import Foundation

/// Pure parsing/conversion helpers for the international weather providers —
/// separated for unit testing (the network side lives in NWSForecastFetcher's
/// provider chain).
enum IntlWeatherParsing {

    // MARK: unit conversions

    static func celsiusToF(_ c: Double) -> Double { c * 9 / 5 + 32 }
    static func kmhToMph(_ kmh: Double) -> Double { kmh / 1.609344 }
    static func msToMph(_ ms: Double) -> Double { ms * 2.2369362920544 }

    // MARK: ECCC SWOB observation extraction

    /// Scan a SWOB properties dict for air temperature (°C) — the field is
    /// reliably `air_temp` but station variants exist.
    static func ecccAirTempF(_ props: [String: Any]) -> Double? {
        for key in ["air_temp", "air_temp_1", "avg_air_temp_pst1hr"] {
            if let v = props[key] as? Double { return celsiusToF(v) }
            if let s = props[key] as? String, let v = Double(s) { return celsiusToF(v) }
        }
        return nil
    }

    /// Wind speed in mph from whichever anemometer field the station has;
    /// prefers 10 m sensors, converts by the sibling `-uom` unit (km/h vs m/s).
    static func ecccWindMph(_ props: [String: Any]) -> Double? {
        let windKeys = props.keys.filter {
            $0.lowercased().contains("wnd_spd")
                && !$0.contains("-uom") && !$0.contains("-qa") && !$0.contains("flag")
        }.sorted { a, b in
            // Prefer 10 m tower sensors over precip-gauge anemometers.
            let aTen = a.contains("10m"), bTen = b.contains("10m")
            if aTen != bTen { return aTen }
            return a < b
        }
        for key in windKeys {
            let value: Double?
            if let v = props[key] as? Double { value = v }
            else if let s = props[key] as? String { value = Double(s) }
            else { value = nil }
            guard let v = value, v >= 0 else { continue }
            let uom = (props["\(key)-uom"] as? String)?.lowercased() ?? "km/h"
            return uom.contains("m/s") ? msToMph(v) : kmhToMph(v)
        }
        return nil
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
        return SMNRow(lat: lat, lon: lon, tmaxC: num("tmax"), tminC: num("tmin"),
                      windKmh: num("velvien"), popPct: num("probprec"))
    }

    /// Daily row → current-conditions approximation: midpoint temperature
    /// (SMN method=1 is a daily municipal forecast, not hourly — documented).
    static func conditions(from row: SMNRow) -> ForecastConditions {
        var c = ForecastConditions()
        switch (row.tmaxC, row.tminC) {
        case let (hi?, lo?): c.temperatureF = celsiusToF((hi + lo) / 2)
        case let (hi?, nil): c.temperatureF = celsiusToF(hi)
        case let (nil, lo?): c.temperatureF = celsiusToF(lo)
        default: break
        }
        c.windMph = row.windKmh.map(kmhToMph)
        c.popPercent = row.popPct
        return c
    }

    // MARK: gzip (SMN serves a gzip FILE body, not transport encoding)

    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else { return nil }
        let flags = data[3]
        var offset = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {   // FNAME — null-terminated
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {   // FCOMMENT
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }   // FHCRC
        guard offset < data.count - 8 else { return nil }
        let deflated = data.subdata(in: offset..<(data.count - 8))

        // ISIZE trailer: uncompressed size mod 2^32 — sizes our buffer.
        let isize = data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let capacity = max(Int(isize), deflated.count * 4, 64_000)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            deflated.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.removeSubrange(written..<out.count)
        return out
    }
}
