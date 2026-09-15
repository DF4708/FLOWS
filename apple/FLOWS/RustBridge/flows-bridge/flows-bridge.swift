public func flows_alerts_display_kind_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_alerts_display_kind_names())
}
public func flows_alerts_display_kind<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr) -> Int32 {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alerts_display_kind(eventAsRustStr)
    })
}
public func flows_alerts_display_kind_for_family<GenericToRustStr: ToRustStr>(_ family: GenericToRustStr) -> Int32 {
    return family.toRustStr({ familyAsRustStr in
        __swift_bridge__$flows_alerts_display_kind_for_family(familyAsRustStr)
    })
}
public func flows_alerts_shelter_kind<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr, _ severity_score: Double) -> Int32 {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alerts_shelter_kind(eventAsRustStr, severity_score)
    })
}
public func flows_alerts_is_life_safety<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr) -> Bool {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alerts_is_life_safety(eventAsRustStr)
    })
}
public func flows_alerts_is_lookout<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr) -> Bool {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alerts_is_lookout(eventAsRustStr)
    })
}
public func flows_alerts_action<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr, _ severity_score: Double, _ has_expiry: Bool, _ seconds_until_expiry: Double) -> Int32 {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alerts_action(eventAsRustStr, severity_score, has_expiry, seconds_until_expiry)
    })
}
public func flows_alerts_threat_rank<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr, _ severity_score: Double) -> Int32 {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alerts_threat_rank(eventAsRustStr, severity_score)
    })
}










public func flows_risk_green_min() -> Double {
    __swift_bridge__$flows_risk_green_min()
}
public func flows_risk_yellow_min() -> Double {
    __swift_bridge__$flows_risk_yellow_min()
}
public func flows_risk_red_min() -> Double {
    __swift_bridge__$flows_risk_red_min()
}
public func flows_secondary_ceiling() -> Double {
    __swift_bridge__$flows_secondary_ceiling()
}
public func flows_acute_nudge() -> Double {
    __swift_bridge__$flows_acute_nudge()
}
public func flows_primary_families() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_primary_families())
}
public func flows_secondary_families() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_secondary_families())
}
public func flows_acute_families() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_acute_families())
}
public func flows_weighted_family_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_weighted_family_names())
}
public func flows_weighted_family_values() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_weighted_family_values())
}
public func flows_risk_band_code(_ score: Double) -> UInt8 {
    __swift_bridge__$flows_risk_band_code(score)
}
public func flows_piecewise_score(_ value: Double, _ low: Double, _ medium: Double, _ high: Double) -> Double {
    __swift_bridge__$flows_piecewise_score(value, low, medium, high)
}
public func flows_temperature_risk(_ temp_f: Double, _ comfort_low_f: Double, _ comfort_high_f: Double, _ record_low_f: Double, _ record_high_f: Double) -> Double {
    __swift_bridge__$flows_temperature_risk(temp_f, comfort_low_f, comfort_high_f, record_low_f, record_high_f)
}
public func flows_temperature_anomalous(_ temp_f: Double, _ comfort_low_f: Double, _ comfort_high_f: Double, _ record_low_f: Double, _ record_high_f: Double) -> Bool {
    __swift_bridge__$flows_temperature_anomalous(temp_f, comfort_low_f, comfort_high_f, record_low_f, record_high_f)
}
public func flows_wind_risk(_ mph: Double) -> Double {
    __swift_bridge__$flows_wind_risk(mph)
}
public func flows_pop_risk(_ pct: Double) -> Double {
    __swift_bridge__$flows_pop_risk(pct)
}
public func flows_forecast_composite(_ temp: Double, _ wind: Double, _ pop: Double) -> Double {
    __swift_bridge__$flows_forecast_composite(temp, wind, pop)
}
public func flows_noisy_or_named<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ scores: UnsafeBufferPointer<Double>) -> Double {
    return names.toRustStr({ namesAsRustStr in
        __swift_bridge__$flows_noisy_or_named(namesAsRustStr, scores.toFfiSlice())
    })
}
public func flows_realized_risk_dense(_ scores: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_realized_risk_dense(scores.toFfiSlice())
}
public func flows_flood_elevation_multiplier(_ sample_elevation: Double, _ has_sample_elevation: Bool, _ local_min_elevation: Double, _ has_local_min_elevation: Bool, _ qpf_inches: Double, _ has_qpf_inches: Bool, _ supporting_evidence: Double) -> Double {
    __swift_bridge__$flows_flood_elevation_multiplier(sample_elevation, has_sample_elevation, local_min_elevation, has_local_min_elevation, qpf_inches, has_qpf_inches, supporting_evidence)
}
public func flows_ranking_risk(_ band: Double, _ zip_exposure: Double, _ seasonal_prior: Double, _ prior_confidence: Double) -> Double {
    __swift_bridge__$flows_ranking_risk(band, zip_exposure, seasonal_prior, prior_confidence)
}
public func flows_alert_family_index<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr) -> Int32 {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alert_family_index(eventAsRustStr)
    })
}
public func flows_peak_family_position<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ scores: UnsafeBufferPointer<Double>, _ floor: Double) -> Int32 {
    return names.toRustStr({ namesAsRustStr in
        __swift_bridge__$flows_peak_family_position(namesAsRustStr, scores.toFfiSlice(), floor)
    })
}
public func flows_dominant_family_position<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ scores: UnsafeBufferPointer<Double>, _ floor: Double) -> Int32 {
    return names.toRustStr({ namesAsRustStr in
        __swift_bridge__$flows_dominant_family_position(namesAsRustStr, scores.toFfiSlice(), floor)
    })
}
public func flows_displayed_band(_ weighted: Double, _ peak: Double) -> Double {
    __swift_bridge__$flows_displayed_band(weighted, peak)
}
public func flows_decode_polyline_lonlat(_ bytes: UnsafeBufferPointer<UInt8>) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_decode_polyline_lonlat(bytes.toFfiSlice()))
}








