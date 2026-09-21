public func flows_alert_text_evaluate_escalation<GenericToRustStr: ToRustStr>(_ complete: Bool, _ mean: Double, _ peak: Double, _ peak_alert_id: GenericToRustStr, _ has_peak_alert_id: Bool, _ baseline: Double, _ dismissed_risk: Double, _ dismissed_joined: GenericToRustStr, _ dismissed_lens: UnsafeBufferPointer<Int64>, _ dismissed_count: Int64) -> FlowsAlertEscalation {
    return dismissed_joined.toRustStr({ dismissed_joinedAsRustStr in
        return peak_alert_id.toRustStr({ peak_alert_idAsRustStr in
        __swift_bridge__$flows_alert_text_evaluate_escalation(complete, mean, peak, peak_alert_idAsRustStr, has_peak_alert_id, baseline, dismissed_risk, dismissed_joinedAsRustStr, dismissed_lens.toFfiSlice(), dismissed_count).intoSwiftRepr()
    })
    })
}
public func flows_alert_text_escalation_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_escalation_constants())
}
public func flows_alert_text_color_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_color_names())
}
public func flows_alert_text_brands() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_brands())
}
public func flows_alert_text_describes_an_entity<GenericToRustStr: ToRustStr>(_ event: GenericToRustStr) -> Bool {
    return event.toRustStr({ eventAsRustStr in
        __swift_bridge__$flows_alert_text_describes_an_entity(eventAsRustStr)
    })
}
public func flows_alert_text_vehicle<GenericToRustStr: ToRustStr>(_ text: GenericToRustStr) -> FlowsAlertVehicle {
    return text.toRustStr({ textAsRustStr in
        __swift_bridge__$flows_alert_text_vehicle(textAsRustStr).intoSwiftRepr()
    })
}
public func flows_alert_text_person<GenericToRustStr: ToRustStr>(_ text: GenericToRustStr) -> FlowsAlertPerson {
    return text.toRustStr({ textAsRustStr in
        __swift_bridge__$flows_alert_text_person(textAsRustStr).intoSwiftRepr()
    })
}
public func flows_alert_text_phrases(_ kind: UInt8) -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_phrases(kind))
}
public func flows_alert_text_match_order() -> RustVec<UInt8> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_match_order())
}
public func flows_alert_text_road_words() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_road_words())
}
public func flows_alert_text_call_kind<GenericToRustStr: ToRustStr>(_ transcript: GenericToRustStr) -> Int64 {
    return transcript.toRustStr({ transcriptAsRustStr in
        __swift_bridge__$flows_alert_text_call_kind(transcriptAsRustStr)
    })
}
public func flows_alert_text_place_phrase<GenericToRustStr: ToRustStr>(_ transcript: GenericToRustStr) -> RustString {
    return transcript.toRustStr({ transcriptAsRustStr in
        RustString(ptr: __swift_bridge__$flows_alert_text_place_phrase(transcriptAsRustStr))
    })
}
public func flows_alert_text_lifetime_seconds(_ kind: UInt8) -> Double {
    __swift_bridge__$flows_alert_text_lifetime_seconds(kind)
}
public func flows_alert_text_is_expired(_ kind: UInt8, _ heard_at: Double, _ now: Double) -> Bool {
    __swift_bridge__$flows_alert_text_is_expired(kind, heard_at, now)
}
public func flows_alert_text_pin_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_pin_constants())
}
public func flows_alert_text_visible(_ kinds: UnsafeBufferPointer<UInt8>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ heard_at: UnsafeBufferPointer<Double>, _ has_position: Bool, _ lat: Double, _ lon: Double, _ corridor_lats: UnsafeBufferPointer<Double>, _ corridor_lons: UnsafeBufferPointer<Double>, _ corridor_count: Int64, _ now: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_visible(kinds.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), heard_at.toFfiSlice(), has_position, lat, lon, corridor_lats.toFfiSlice(), corridor_lons.toFfiSlice(), corridor_count, now))
}
public func flows_alert_text_merged_keep(_ kinds: UnsafeBufferPointer<UInt8>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ new_kind: UInt8, _ new_lat: Double, _ new_lon: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_alert_text_merged_keep(kinds.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), new_kind, new_lat, new_lon))
}
public struct FlowsAlertVehicle {
    public var has: Bool
    public var kind: UInt8
    public var has_color: Bool
    public var color_index: Int64
    public var has_brand: Bool
    public var brand_index: Int64

    public init(has: Bool,kind: UInt8,has_color: Bool,color_index: Int64,has_brand: Bool,brand_index: Int64) {
        self.has = has
        self.kind = kind
        self.has_color = has_color
        self.color_index = color_index
        self.has_brand = has_brand
        self.brand_index = brand_index
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsAlertVehicle {
        { let val = self; return __swift_bridge__$FlowsAlertVehicle(has: val.has, kind: val.kind, has_color: val.has_color, color_index: val.color_index, has_brand: val.has_brand, brand_index: val.brand_index); }()
    }
}
extension __swift_bridge__$FlowsAlertVehicle {
    @inline(__always)
    func intoSwiftRepr() -> FlowsAlertVehicle {
        { let val = self; return FlowsAlertVehicle(has: val.has, kind: val.kind, has_color: val.has_color, color_index: val.color_index, has_brand: val.has_brand, brand_index: val.brand_index); }()
    }
}
extension __swift_bridge__$Option$FlowsAlertVehicle {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsAlertVehicle> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsAlertVehicle>) -> __swift_bridge__$Option$FlowsAlertVehicle {
        if let v = val {
            return __swift_bridge__$Option$FlowsAlertVehicle(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsAlertVehicle(is_some: false, val: __swift_bridge__$FlowsAlertVehicle())
        }
    }
}
public struct FlowsAlertPerson {
    public var has: Bool
    public var is_child: Bool
    public var has_color: Bool
    public var color_index: Int64

    public init(has: Bool,is_child: Bool,has_color: Bool,color_index: Int64) {
        self.has = has
        self.is_child = is_child
        self.has_color = has_color
        self.color_index = color_index
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsAlertPerson {
        { let val = self; return __swift_bridge__$FlowsAlertPerson(has: val.has, is_child: val.is_child, has_color: val.has_color, color_index: val.color_index); }()
    }
}
extension __swift_bridge__$FlowsAlertPerson {
    @inline(__always)
    func intoSwiftRepr() -> FlowsAlertPerson {
        { let val = self; return FlowsAlertPerson(has: val.has, is_child: val.is_child, has_color: val.has_color, color_index: val.color_index); }()
    }
}
extension __swift_bridge__$Option$FlowsAlertPerson {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsAlertPerson> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsAlertPerson>) -> __swift_bridge__$Option$FlowsAlertPerson {
        if let v = val {
            return __swift_bridge__$Option$FlowsAlertPerson(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsAlertPerson(is_some: false, val: __swift_bridge__$FlowsAlertPerson())
        }
    }
}
public struct FlowsAlertEscalation {
    public var baseline: Double
    public var has_trigger: Bool
    public var trigger_kind: UInt8
    public var risk: Double

    public init(baseline: Double,has_trigger: Bool,trigger_kind: UInt8,risk: Double) {
        self.baseline = baseline
        self.has_trigger = has_trigger
        self.trigger_kind = trigger_kind
        self.risk = risk
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsAlertEscalation {
        { let val = self; return __swift_bridge__$FlowsAlertEscalation(baseline: val.baseline, has_trigger: val.has_trigger, trigger_kind: val.trigger_kind, risk: val.risk); }()
    }
}
extension __swift_bridge__$FlowsAlertEscalation {
    @inline(__always)
    func intoSwiftRepr() -> FlowsAlertEscalation {
        { let val = self; return FlowsAlertEscalation(baseline: val.baseline, has_trigger: val.has_trigger, trigger_kind: val.trigger_kind, risk: val.risk); }()
    }
}
extension __swift_bridge__$Option$FlowsAlertEscalation {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsAlertEscalation> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsAlertEscalation>) -> __swift_bridge__$Option$FlowsAlertEscalation {
        if let v = val {
            return __swift_bridge__$Option$FlowsAlertEscalation(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsAlertEscalation(is_some: false, val: __swift_bridge__$FlowsAlertEscalation())
        }
    }
}


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


public func flows_climate_south_anchor() -> Double {
    __swift_bridge__$flows_climate_south_anchor()
}
public func flows_climate_north_anchor() -> Double {
    __swift_bridge__$flows_climate_north_anchor()
}
public func flows_climate_pitch_degrees() -> Double {
    __swift_bridge__$flows_climate_pitch_degrees()
}
public func flows_climate_min_latitude() -> Double {
    __swift_bridge__$flows_climate_min_latitude()
}
public func flows_climate_max_latitude() -> Double {
    __swift_bridge__$flows_climate_max_latitude()
}
public func flows_climate_reference_elevation_meters() -> Double {
    __swift_bridge__$flows_climate_reference_elevation_meters()
}
public func flows_climate_meters_per_band_step() -> Double {
    __swift_bridge__$flows_climate_meters_per_band_step()
}
public func flows_climate_band_index(_ latitude: Double) -> FlowsClimateOptional {
    __swift_bridge__$flows_climate_band_index(latitude).intoSwiftRepr()
}
public func flows_climate_elevation_band_shift(_ elevation_meters: Double, _ has_elevation: Bool) -> Int64 {
    __swift_bridge__$flows_climate_elevation_band_shift(elevation_meters, has_elevation)
}
public func flows_climate_band_profile(_ latitude: Double, _ elevation_meters: Double, _ has_elevation: Bool) -> FlowsClimateProfile {
    __swift_bridge__$flows_climate_band_profile(latitude, elevation_meters, has_elevation).intoSwiftRepr()
}
public func flows_climate_type_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_climate_type_names())
}
public func flows_climate_type_profile(_ code: UInt8) -> FlowsClimateProfile {
    __swift_bridge__$flows_climate_type_profile(code).intoSwiftRepr()
}
public func flows_climate_classify(_ latitude: Double, _ longitude: Double, _ elevation_meters: Double, _ has_elevation: Bool) -> UInt8 {
    __swift_bridge__$flows_climate_classify(latitude, longitude, elevation_meters, has_elevation)
}
public func flows_climate_temp_sigma_f() -> Double {
    __swift_bridge__$flows_climate_temp_sigma_f()
}
public func flows_climate_seasonal_norms(_ week: Int64, _ latitude: Double, _ longitude: Double, _ elevation_meters: Double, _ has_elevation: Bool) -> FlowsClimateNorms {
    __swift_bridge__$flows_climate_seasonal_norms(week, latitude, longitude, elevation_meters, has_elevation).intoSwiftRepr()
}
public func flows_climate_temperature_beyond_normal(_ temp_f: Double, _ week_low_f: Double, _ week_high_f: Double, _ wind_mean_mph: Double, _ wind_sigma_mph: Double) -> Bool {
    __swift_bridge__$flows_climate_temperature_beyond_normal(temp_f, week_low_f, week_high_f, wind_mean_mph, wind_sigma_mph)
}
public func flows_climate_wind_beyond_normal(_ wind_mph: Double, _ week_low_f: Double, _ week_high_f: Double, _ wind_mean_mph: Double, _ wind_sigma_mph: Double) -> Bool {
    __swift_bridge__$flows_climate_wind_beyond_normal(wind_mph, week_low_f, week_high_f, wind_mean_mph, wind_sigma_mph)
}
public func flows_climate_profile(_ latitude: Double, _ longitude: Double, _ elevation_meters: Double, _ has_elevation: Bool) -> FlowsClimateProfile {
    __swift_bridge__$flows_climate_profile(latitude, longitude, elevation_meters, has_elevation).intoSwiftRepr()
}
public func flows_climate_precise_cell(_ latitude: Double, _ longitude: Double) -> FlowsClimateCell {
    __swift_bridge__$flows_climate_precise_cell(latitude, longitude).intoSwiftRepr()
}
public func flows_climate_precise_cell_near_home(_ key: Int64, _ home_latitude: Double, _ home_longitude: Double) -> Bool {
    __swift_bridge__$flows_climate_precise_cell_near_home(key, home_latitude, home_longitude)
}
public func flows_climate_civil_twilight_degrees() -> Double {
    __swift_bridge__$flows_climate_civil_twilight_degrees()
}
public func flows_climate_julian_day(_ now: Double) -> Double {
    __swift_bridge__$flows_climate_julian_day(now)
}
public func flows_climate_midnight_jd(_ jd: Double) -> Double {
    __swift_bridge__$flows_climate_midnight_jd(jd)
}
public func flows_climate_solar_terms(_ jd: Double) -> FlowsClimateSolarTerms {
    __swift_bridge__$flows_climate_solar_terms(jd).intoSwiftRepr()
}
public func flows_climate_hour_angle_minutes(_ latitude: Double, _ declination: Double, _ angle: Double) -> Double {
    __swift_bridge__$flows_climate_hour_angle_minutes(latitude, declination, angle)
}
public func flows_climate_twilight(_ latitude: Double, _ longitude: Double, _ now: Double, _ angle: Double) -> FlowsClimateTwilight {
    __swift_bridge__$flows_climate_twilight(latitude, longitude, now, angle).intoSwiftRepr()
}
public func flows_climate_is_night(_ latitude: Double, _ longitude: Double, _ now: Double) -> Bool {
    __swift_bridge__$flows_climate_is_night(latitude, longitude, now)
}
public func flows_climate_solar_elevation(_ latitude: Double, _ longitude: Double, _ now: Double) -> Double {
    __swift_bridge__$flows_climate_solar_elevation(latitude, longitude, now)
}
public func flows_climate_next_change(_ latitude: Double, _ longitude: Double, _ now: Double) -> Double {
    __swift_bridge__$flows_climate_next_change(latitude, longitude, now)
}
public func flows_climate_score_max() -> Double {
    __swift_bridge__$flows_climate_score_max()
}
public func flows_climate_week_trig(_ week: Int64) -> FlowsClimateWeekTrig {
    __swift_bridge__$flows_climate_week_trig(week).intoSwiftRepr()
}
public func flows_climate_is_active(_ expires: Double, _ has_expires: Bool, _ arrival_offset: Double, _ now: Double) -> Bool {
    __swift_bridge__$flows_climate_is_active(expires, has_expires, arrival_offset, now)
}
public func flows_climate_max_arrival_samples() -> Int64 {
    __swift_bridge__$flows_climate_max_arrival_samples()
}
public func flows_climate_arrival_offsets(_ sample_count: Int64, _ total_travel_seconds: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_climate_arrival_offsets(sample_count, total_travel_seconds))
}
public func flows_climate_parse_flhh(_ data: UnsafeBufferPointer<UInt8>) -> Optional<FlowsHarmonicTable> {
    { let val = __swift_bridge__$flows_climate_parse_flhh(data.toFfiSlice()); if val != nil { return FlowsHarmonicTable(ptr: val!) } else { return nil } }()
}
public struct FlowsClimateProfile {
    public var has: Double
    public var band: Int64
    public var comfort_low_f: Double
    public var comfort_high_f: Double
    public var record_low_f: Double
    public var record_high_f: Double
    public var wind_low: Double
    public var wind_medium: Double
    public var wind_high: Double
    public var pop_low: Double
    public var pop_medium: Double
    public var pop_high: Double

    public init(has: Double,band: Int64,comfort_low_f: Double,comfort_high_f: Double,record_low_f: Double,record_high_f: Double,wind_low: Double,wind_medium: Double,wind_high: Double,pop_low: Double,pop_medium: Double,pop_high: Double) {
        self.has = has
        self.band = band
        self.comfort_low_f = comfort_low_f
        self.comfort_high_f = comfort_high_f
        self.record_low_f = record_low_f
        self.record_high_f = record_high_f
        self.wind_low = wind_low
        self.wind_medium = wind_medium
        self.wind_high = wind_high
        self.pop_low = pop_low
        self.pop_medium = pop_medium
        self.pop_high = pop_high
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateProfile {
        { let val = self; return __swift_bridge__$FlowsClimateProfile(has: val.has, band: val.band, comfort_low_f: val.comfort_low_f, comfort_high_f: val.comfort_high_f, record_low_f: val.record_low_f, record_high_f: val.record_high_f, wind_low: val.wind_low, wind_medium: val.wind_medium, wind_high: val.wind_high, pop_low: val.pop_low, pop_medium: val.pop_medium, pop_high: val.pop_high); }()
    }
}
extension __swift_bridge__$FlowsClimateProfile {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateProfile {
        { let val = self; return FlowsClimateProfile(has: val.has, band: val.band, comfort_low_f: val.comfort_low_f, comfort_high_f: val.comfort_high_f, record_low_f: val.record_low_f, record_high_f: val.record_high_f, wind_low: val.wind_low, wind_medium: val.wind_medium, wind_high: val.wind_high, pop_low: val.pop_low, pop_medium: val.pop_medium, pop_high: val.pop_high); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateProfile {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateProfile> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateProfile>) -> __swift_bridge__$Option$FlowsClimateProfile {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateProfile(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateProfile(is_some: false, val: __swift_bridge__$FlowsClimateProfile())
        }
    }
}
public struct FlowsClimateNorms {
    public var week_low_f: Double
    public var week_high_f: Double
    public var wind_mean_mph: Double
    public var wind_sigma_mph: Double

    public init(week_low_f: Double,week_high_f: Double,wind_mean_mph: Double,wind_sigma_mph: Double) {
        self.week_low_f = week_low_f
        self.week_high_f = week_high_f
        self.wind_mean_mph = wind_mean_mph
        self.wind_sigma_mph = wind_sigma_mph
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateNorms {
        { let val = self; return __swift_bridge__$FlowsClimateNorms(week_low_f: val.week_low_f, week_high_f: val.week_high_f, wind_mean_mph: val.wind_mean_mph, wind_sigma_mph: val.wind_sigma_mph); }()
    }
}
extension __swift_bridge__$FlowsClimateNorms {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateNorms {
        { let val = self; return FlowsClimateNorms(week_low_f: val.week_low_f, week_high_f: val.week_high_f, wind_mean_mph: val.wind_mean_mph, wind_sigma_mph: val.wind_sigma_mph); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateNorms {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateNorms> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateNorms>) -> __swift_bridge__$Option$FlowsClimateNorms {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateNorms(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateNorms(is_some: false, val: __swift_bridge__$FlowsClimateNorms())
        }
    }
}
public struct FlowsClimateSolarTerms {
    public var declination: Double
    public var equation_of_time: Double

    public init(declination: Double,equation_of_time: Double) {
        self.declination = declination
        self.equation_of_time = equation_of_time
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateSolarTerms {
        { let val = self; return __swift_bridge__$FlowsClimateSolarTerms(declination: val.declination, equation_of_time: val.equation_of_time); }()
    }
}
extension __swift_bridge__$FlowsClimateSolarTerms {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateSolarTerms {
        { let val = self; return FlowsClimateSolarTerms(declination: val.declination, equation_of_time: val.equation_of_time); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateSolarTerms {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateSolarTerms> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateSolarTerms>) -> __swift_bridge__$Option$FlowsClimateSolarTerms {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateSolarTerms(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateSolarTerms(is_some: false, val: __swift_bridge__$FlowsClimateSolarTerms())
        }
    }
}
public struct FlowsClimateTwilight {
    public var has: Double
    public var dawn: Double
    public var dusk: Double

    public init(has: Double,dawn: Double,dusk: Double) {
        self.has = has
        self.dawn = dawn
        self.dusk = dusk
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateTwilight {
        { let val = self; return __swift_bridge__$FlowsClimateTwilight(has: val.has, dawn: val.dawn, dusk: val.dusk); }()
    }
}
extension __swift_bridge__$FlowsClimateTwilight {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateTwilight {
        { let val = self; return FlowsClimateTwilight(has: val.has, dawn: val.dawn, dusk: val.dusk); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateTwilight {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateTwilight> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateTwilight>) -> __swift_bridge__$Option$FlowsClimateTwilight {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateTwilight(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateTwilight(is_some: false, val: __swift_bridge__$FlowsClimateTwilight())
        }
    }
}
public struct FlowsClimateWeekTrig {
    public var cos_t: Double
    public var sin_t: Double
    public var cos_2t: Double
    public var sin_2t: Double

    public init(cos_t: Double,sin_t: Double,cos_2t: Double,sin_2t: Double) {
        self.cos_t = cos_t
        self.sin_t = sin_t
        self.cos_2t = cos_2t
        self.sin_2t = sin_2t
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateWeekTrig {
        { let val = self; return __swift_bridge__$FlowsClimateWeekTrig(cos_t: val.cos_t, sin_t: val.sin_t, cos_2t: val.cos_2t, sin_2t: val.sin_2t); }()
    }
}
extension __swift_bridge__$FlowsClimateWeekTrig {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateWeekTrig {
        { let val = self; return FlowsClimateWeekTrig(cos_t: val.cos_t, sin_t: val.sin_t, cos_2t: val.cos_2t, sin_2t: val.sin_2t); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateWeekTrig {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateWeekTrig> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateWeekTrig>) -> __swift_bridge__$Option$FlowsClimateWeekTrig {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateWeekTrig(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateWeekTrig(is_some: false, val: __swift_bridge__$FlowsClimateWeekTrig())
        }
    }
}
public struct FlowsClimateOptional {
    public var is_some: Double
    public var value: Double

    public init(is_some: Double,value: Double) {
        self.is_some = is_some
        self.value = value
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateOptional {
        { let val = self; return __swift_bridge__$FlowsClimateOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$FlowsClimateOptional {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateOptional {
        { let val = self; return FlowsClimateOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateOptional {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateOptional> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateOptional>) -> __swift_bridge__$Option$FlowsClimateOptional {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateOptional(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateOptional(is_some: false, val: __swift_bridge__$FlowsClimateOptional())
        }
    }
}
public struct FlowsClimateCell {
    public var has: Bool
    public var key: Int64

    public init(has: Bool,key: Int64) {
        self.has = has
        self.key = key
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsClimateCell {
        { let val = self; return __swift_bridge__$FlowsClimateCell(has: val.has, key: val.key); }()
    }
}
extension __swift_bridge__$FlowsClimateCell {
    @inline(__always)
    func intoSwiftRepr() -> FlowsClimateCell {
        { let val = self; return FlowsClimateCell(has: val.has, key: val.key); }()
    }
}
extension __swift_bridge__$Option$FlowsClimateCell {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsClimateCell> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsClimateCell>) -> __swift_bridge__$Option$FlowsClimateCell {
        if let v = val {
            return __swift_bridge__$Option$FlowsClimateCell(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsClimateCell(is_some: false, val: __swift_bridge__$FlowsClimateCell())
        }
    }
}

public class FlowsHarmonicTable: FlowsHarmonicTableRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FlowsHarmonicTable$_free(ptr)
        }
    }
}
public class FlowsHarmonicTableRefMut: FlowsHarmonicTableRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FlowsHarmonicTableRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FlowsHarmonicTableRef {
    public func families() -> RustVec<RustString> {
        RustVec(ptr: __swift_bridge__$FlowsHarmonicTable$families(ptr))
    }

    public func zips() -> RustVec<RustString> {
        RustVec(ptr: __swift_bridge__$FlowsHarmonicTable$zips(ptr))
    }

    public func family_count() -> UInt32 {
        __swift_bridge__$FlowsHarmonicTable$family_count(ptr)
    }

    public func zip_index<GenericToRustStr: ToRustStr>(_ zip: GenericToRustStr) -> Int32 {
        return zip.toRustStr({ zipAsRustStr in
            __swift_bridge__$FlowsHarmonicTable$zip_index(ptr, zipAsRustStr)
        })
    }

    public func score_named<GenericToRustStr: ToRustStr>(_ zip: GenericToRustStr, _ family: GenericToRustStr, _ week: Int64) -> FlowsClimateOptional {
        return family.toRustStr({ familyAsRustStr in
            return zip.toRustStr({ zipAsRustStr in
            __swift_bridge__$FlowsHarmonicTable$score_named(ptr, zipAsRustStr, familyAsRustStr, week).intoSwiftRepr()
        })
        })
    }

    public func score_row(_ zip_index: Int64, _ family_index: Int64, _ cos_t: Double, _ sin_t: Double, _ cos_2t: Double, _ sin_2t: Double) -> Double {
        __swift_bridge__$FlowsHarmonicTable$score_row(ptr, zip_index, family_index, cos_t, sin_t, cos_2t, sin_2t)
    }
}
extension FlowsHarmonicTable: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FlowsHarmonicTable$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FlowsHarmonicTable$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FlowsHarmonicTable) {
        __swift_bridge__$Vec_FlowsHarmonicTable$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FlowsHarmonicTable$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FlowsHarmonicTable(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsHarmonicTableRef> {
        let pointer = __swift_bridge__$Vec_FlowsHarmonicTable$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsHarmonicTableRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsHarmonicTableRefMut> {
        let pointer = __swift_bridge__$Vec_FlowsHarmonicTable$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsHarmonicTableRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FlowsHarmonicTableRef> {
        UnsafePointer<FlowsHarmonicTableRef>(OpaquePointer(__swift_bridge__$Vec_FlowsHarmonicTable$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FlowsHarmonicTable$len(vecPtr)
    }
}



public func flows_forecast_predictor_family_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_forecast_predictor_family_names())
}
public func flows_forecast_score(_ temperature_f: Double, _ has_temperature: Bool, _ wind_mph: Double, _ has_wind: Bool, _ pop_percent: Double, _ has_pop: Bool, _ latitude: Double, _ longitude: Double, _ elevation_meters: Double, _ has_elevation: Bool) -> Double {
    __swift_bridge__$flows_forecast_score(temperature_f, has_temperature, wind_mph, has_wind, pop_percent, has_pop, latitude, longitude, elevation_meters, has_elevation)
}
public func flows_forecast_predictor_families(_ temperature_f: Double, _ has_temperature: Bool, _ wind_mph: Double, _ has_wind: Bool, _ pop_percent: Double, _ has_pop: Bool, _ latitude: Double, _ longitude: Double, _ elevation_meters: Double, _ has_elevation: Bool) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_forecast_predictor_families(temperature_f, has_temperature, wind_mph, has_wind, pop_percent, has_pop, latitude, longitude, elevation_meters, has_elevation))
}


public func flows_geo_bearing_degrees(_ a_lat: Double, _ a_lon: Double, _ b_lat: Double, _ b_lon: Double) -> Double {
    __swift_bridge__$flows_geo_bearing_degrees(a_lat, a_lon, b_lat, b_lon)
}
public func flows_geo_ahead_cone_degrees() -> Double {
    __swift_bridge__$flows_geo_ahead_cone_degrees()
}
public func flows_geo_fuel_corridor_meters() -> Double {
    __swift_bridge__$flows_geo_fuel_corridor_meters()
}
public func flows_geo_fuel_station_is_reachable(_ station_lat: Double, _ station_lon: Double, _ here_lat: Double, _ here_lon: Double, _ course_degrees: Double, _ route_lats: UnsafeBufferPointer<Double>, _ route_lons: UnsafeBufferPointer<Double>, _ route_count: Int64, _ corridor_meters: Double) -> Bool {
    __swift_bridge__$flows_geo_fuel_station_is_reachable(station_lat, station_lon, here_lat, here_lon, course_degrees, route_lats.toFfiSlice(), route_lons.toFfiSlice(), route_count, corridor_meters)
}
public func flows_geo_corridor_nearest(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ point_counts: UnsafeBufferPointer<Int64>, _ corridor_count: Int64, _ lat: Double, _ lon: Double) -> Int64 {
    __swift_bridge__$flows_geo_corridor_nearest(lats.toFfiSlice(), lons.toFfiSlice(), point_counts.toFfiSlice(), corridor_count, lat, lon)
}


public func flows_hazard_air_score(_ us_aqi: Double) -> Double {
    __swift_bridge__$flows_hazard_air_score(us_aqi)
}
public func flows_hazard_uv_score(_ index: Double) -> Double {
    __swift_bridge__$flows_hazard_uv_score(index)
}
public func flows_hazard_space_weather_score(_ scale: Int64) -> Double {
    __swift_bridge__$flows_hazard_space_weather_score(scale)
}
public func flows_hazard_radiation_space_weather_score(_ s_scale: Int64, _ g_scale: Int64, _ latitude: Double) -> Double {
    __swift_bridge__$flows_hazard_radiation_space_weather_score(s_scale, g_scale, latitude)
}
public func flows_hazard_volcano_alert_score<GenericToRustStr: ToRustStr>(_ level: GenericToRustStr) -> Double {
    return level.toRustStr({ levelAsRustStr in
        __swift_bridge__$flows_hazard_volcano_alert_score(levelAsRustStr)
    })
}
public func flows_hazard_avalanche_rating_score(_ rating: Int64) -> Double {
    __swift_bridge__$flows_hazard_avalanche_rating_score(rating)
}
public func flows_hazard_tropical_intensity_score(_ max_wind_kt: Double) -> Double {
    __swift_bridge__$flows_hazard_tropical_intensity_score(max_wind_kt)
}
public func flows_hazard_tsunami_level_score<GenericToRustStr: ToRustStr>(_ level: GenericToRustStr) -> Double {
    return level.toRustStr({ levelAsRustStr in
        __swift_bridge__$flows_hazard_tsunami_level_score(levelAsRustStr)
    })
}
public func flows_hazard_spc_categorical_score(_ dn: Int64) -> Double {
    __swift_bridge__$flows_hazard_spc_categorical_score(dn)
}
public func flows_hazard_flood_category_score<GenericToRustStr: ToRustStr>(_ category: GenericToRustStr) -> Double {
    return category.toRustStr({ categoryAsRustStr in
        __swift_bridge__$flows_hazard_flood_category_score(categoryAsRustStr)
    })
}
public func flows_hazard_severity_score<GenericToRustStr: ToRustStr>(_ severity: GenericToRustStr) -> Double {
    return severity.toRustStr({ severityAsRustStr in
        __swift_bridge__$flows_hazard_severity_score(severityAsRustStr)
    })
}
public func flows_hazard_backup_severity<GenericToRustStr: ToRustStr>(_ phenomena: GenericToRustStr) -> Double {
    return phenomena.toRustStr({ phenomenaAsRustStr in
        __swift_bridge__$flows_hazard_backup_severity(phenomenaAsRustStr)
    })
}
public func flows_hazard_fire_score(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ frps: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_fire_score(lats.toFfiSlice(), lons.toFfiSlice(), frps.toFfiSlice(), lat, lon)
}
public func flows_hazard_seismic_score(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ magnitudes: UnsafeBufferPointer<Double>, _ age_hours: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_seismic_score(lats.toFfiSlice(), lons.toFfiSlice(), magnitudes.toFfiSlice(), age_hours.toFfiSlice(), lat, lon)
}
public func flows_hazard_water_proximity_score(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_water_proximity_score(lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_closure_score(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_closure_score(lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_tropical_score(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ max_wind_kts: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_tropical_score(lats.toFfiSlice(), lons.toFfiSlice(), max_wind_kts.toFfiSlice(), lat, lon)
}
public func flows_hazard_flood_gauge_score<GenericToRustStr: ToRustStr>(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ categories_joined: GenericToRustStr, _ lat: Double, _ lon: Double) -> Double {
    return categories_joined.toRustStr({ categories_joinedAsRustStr in
        __swift_bridge__$flows_hazard_flood_gauge_score(lats.toFfiSlice(), lons.toFfiSlice(), categories_joinedAsRustStr, lat, lon)
    })
}
public func flows_hazard_volcanic_score<GenericToRustStr: ToRustStr>(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ levels_joined: GenericToRustStr, _ lat: Double, _ lon: Double) -> Double {
    return levels_joined.toRustStr({ levels_joinedAsRustStr in
        __swift_bridge__$flows_hazard_volcanic_score(lats.toFfiSlice(), lons.toFfiSlice(), levels_joinedAsRustStr, lat, lon)
    })
}
public func flows_hazard_tsunami_score<GenericToRustStr: ToRustStr>(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ levels_joined: GenericToRustStr, _ lat: Double, _ lon: Double) -> Double {
    return levels_joined.toRustStr({ levels_joinedAsRustStr in
        __swift_bridge__$flows_hazard_tsunami_score(lats.toFfiSlice(), lons.toFfiSlice(), levels_joinedAsRustStr, lat, lon)
    })
}
public func flows_hazard_point_in_polygon(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Bool {
    __swift_bridge__$flows_hazard_point_in_polygon(lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_ring_contains(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Bool {
    __swift_bridge__$flows_hazard_ring_contains(lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_fire_perimeter_score(_ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_fire_perimeter_score(ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_avalanche_score(_ zone_ring_counts: UnsafeBufferPointer<Int64>, _ ratings: UnsafeBufferPointer<Int64>, _ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_avalanche_score(zone_ring_counts.toFfiSlice(), ratings.toFfiSlice(), ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_outlook_score(_ zone_ring_counts: UnsafeBufferPointer<Int64>, _ scores: UnsafeBufferPointer<Double>, _ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Double {
    __swift_bridge__$flows_hazard_outlook_score(zone_ring_counts.toFfiSlice(), scores.toFfiSlice(), ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_hazard_cell_key(_ lat: Double, _ lon: Double) -> RustString {
    RustString(ptr: __swift_bridge__$flows_hazard_cell_key(lat, lon))
}
public func flows_hazard_states_containing(_ lat: Double, _ lon: Double) -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_hazard_states_containing(lat, lon))
}
public func flows_hazard_marine_regions_containing(_ lat: Double, _ lon: Double) -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_hazard_marine_regions_containing(lat, lon))
}
public func flows_hazard_provisional_samples<GenericToRustStr: ToRustStr>(_ sample_lats: UnsafeBufferPointer<Double>, _ sample_lons: UnsafeBufferPointer<Double>, _ alert_severities: UnsafeBufferPointer<Double>, _ alert_expires: UnsafeBufferPointer<Double>, _ alert_has_expires: UnsafeBufferPointer<Int64>, _ cell_keys_joined: GenericToRustStr, _ cell_alert_counts: UnsafeBufferPointer<Int64>, _ cell_alert_indices: UnsafeBufferPointer<Int64>, _ arrival_offsets: UnsafeBufferPointer<Double>, _ has_offsets: Bool, _ now: Double) -> RustVec<Double> {
    return cell_keys_joined.toRustStr({ cell_keys_joinedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_hazard_provisional_samples(sample_lats.toFfiSlice(), sample_lons.toFfiSlice(), alert_severities.toFfiSlice(), alert_expires.toFfiSlice(), alert_has_expires.toFfiSlice(), cell_keys_joinedAsRustStr, cell_alert_counts.toFfiSlice(), cell_alert_indices.toFfiSlice(), arrival_offsets.toFfiSlice(), has_offsets, now))
    })
}
public func flows_hazard_alerts_covering<GenericToRustStr: ToRustStr>(_ lat: Double, _ lon: Double, _ alert_ring_counts: UnsafeBufferPointer<Int64>, _ alert_zone_counts: UnsafeBufferPointer<Int64>, _ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ alert_zones_joined: GenericToRustStr, _ zone_names_joined: GenericToRustStr, _ zone_ring_counts: UnsafeBufferPointer<Int64>, _ zone_ring_lens: UnsafeBufferPointer<Int64>, _ zone_lats: UnsafeBufferPointer<Double>, _ zone_lons: UnsafeBufferPointer<Double>) -> RustVec<Int64> {
    return zone_names_joined.toRustStr({ zone_names_joinedAsRustStr in
        return alert_zones_joined.toRustStr({ alert_zones_joinedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_hazard_alerts_covering(lat, lon, alert_ring_counts.toFfiSlice(), alert_zone_counts.toFfiSlice(), ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), alert_zones_joinedAsRustStr, zone_names_joinedAsRustStr, zone_ring_counts.toFfiSlice(), zone_ring_lens.toFfiSlice(), zone_lats.toFfiSlice(), zone_lons.toFfiSlice()))
    })
    })
}
public func flows_hazard_all_rings(_ ring_coord_counts: UnsafeBufferPointer<Int64>, _ coord_lens: UnsafeBufferPointer<Int64>, _ values: UnsafeBufferPointer<Double>, _ max_points: Int64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_hazard_all_rings(ring_coord_counts.toFfiSlice(), coord_lens.toFfiSlice(), values.toFfiSlice(), max_points))
}
public func flows_hazard_corridor_noisy_or(_ severities: UnsafeBufferPointer<Double>, _ coverages: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_hazard_corridor_noisy_or(severities.toFfiSlice(), coverages.toFfiSlice())
}
public func flows_hazard_corridor_coverage(_ risks: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_hazard_corridor_coverage(risks.toFfiSlice())
}
public func flows_hazard_worst_first(_ severities: UnsafeBufferPointer<Double>) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_hazard_worst_first(severities.toFfiSlice()))
}
public func flows_hazard_fuel_prices<GenericToRustStr: ToRustStr>(_ xml: GenericToRustStr) -> RustVec<RustString> {
    return xml.toRustStr({ xmlAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_hazard_fuel_prices(xmlAsRustStr))
    })
}
public func flows_hazard_fuel_places<GenericToRustStr: ToRustStr>(_ xml: GenericToRustStr) -> RustVec<RustString> {
    return xml.toRustStr({ xmlAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_hazard_fuel_places(xmlAsRustStr))
    })
}
public func flows_hazard_clip_margin_degrees() -> Double {
    __swift_bridge__$flows_hazard_clip_margin_degrees()
}
public func flows_hazard_snapshot_new() -> FlowsHazardSnapshot {
    FlowsHazardSnapshot(ptr: __swift_bridge__$flows_hazard_snapshot_new())
}

public class FlowsHazardSnapshot: FlowsHazardSnapshotRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FlowsHazardSnapshot$_free(ptr)
        }
    }
}
public class FlowsHazardSnapshotRefMut: FlowsHazardSnapshotRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
extension FlowsHazardSnapshotRefMut {
    public func add_hotspots(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ frps: UnsafeBufferPointer<Double>) {
        __swift_bridge__$FlowsHazardSnapshot$add_hotspots(ptr, lats.toFfiSlice(), lons.toFfiSlice(), frps.toFfiSlice())
    }

    public func add_perimeters(_ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) {
        __swift_bridge__$FlowsHazardSnapshot$add_perimeters(ptr, ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice())
    }

    public func add_quakes(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ magnitudes: UnsafeBufferPointer<Double>, _ age_hours: UnsafeBufferPointer<Double>) {
        __swift_bridge__$FlowsHazardSnapshot$add_quakes(ptr, lats.toFfiSlice(), lons.toFfiSlice(), magnitudes.toFfiSlice(), age_hours.toFfiSlice())
    }

    public func set_space(_ r: Int64, _ s: Int64, _ g: Int64) {
        __swift_bridge__$FlowsHazardSnapshot$set_space(ptr, r, s, g)
    }

    public func add_volcanoes<GenericToRustStr: ToRustStr>(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ levels_joined: GenericToRustStr) {
        levels_joined.toRustStr({ levels_joinedAsRustStr in
            __swift_bridge__$FlowsHazardSnapshot$add_volcanoes(ptr, lats.toFfiSlice(), lons.toFfiSlice(), levels_joinedAsRustStr)
        })
    }

    public func add_avalanche_zones(_ zone_ring_counts: UnsafeBufferPointer<Int64>, _ ratings: UnsafeBufferPointer<Int64>, _ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) {
        __swift_bridge__$FlowsHazardSnapshot$add_avalanche_zones(ptr, zone_ring_counts.toFfiSlice(), ratings.toFfiSlice(), ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice())
    }

    public func add_storms(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ max_wind_kts: UnsafeBufferPointer<Double>) {
        __swift_bridge__$FlowsHazardSnapshot$add_storms(ptr, lats.toFfiSlice(), lons.toFfiSlice(), max_wind_kts.toFfiSlice())
    }

    public func add_tsunamis<GenericToRustStr: ToRustStr>(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ levels_joined: GenericToRustStr) {
        levels_joined.toRustStr({ levels_joinedAsRustStr in
            __swift_bridge__$FlowsHazardSnapshot$add_tsunamis(ptr, lats.toFfiSlice(), lons.toFfiSlice(), levels_joinedAsRustStr)
        })
    }

    public func add_spc_zones(_ zone_ring_counts: UnsafeBufferPointer<Int64>, _ scores: UnsafeBufferPointer<Double>, _ ring_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) {
        __swift_bridge__$FlowsHazardSnapshot$add_spc_zones(ptr, zone_ring_counts.toFfiSlice(), scores.toFfiSlice(), ring_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice())
    }
}
public class FlowsHazardSnapshotRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FlowsHazardSnapshotRef {
    public func clipped(_ min_lat: Double, _ min_lon: Double, _ max_lat: Double, _ max_lon: Double) -> FlowsHazardSnapshot {
        FlowsHazardSnapshot(ptr: __swift_bridge__$FlowsHazardSnapshot$clipped(ptr, min_lat, min_lon, max_lat, max_lon))
    }

    public func live(_ lat: Double, _ lon: Double) -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$live(ptr, lat, lon))
    }

    public func hotspots_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$hotspots_flat(ptr))
    }

    public func perimeters_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$perimeters_flat(ptr))
    }

    public func quakes_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$quakes_flat(ptr))
    }

    public func space() -> RustVec<Int64> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$space(ptr))
    }

    public func volcanoes_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$volcanoes_flat(ptr))
    }

    public func volcano_levels() -> RustVec<RustString> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$volcano_levels(ptr))
    }

    public func avalanche_zones_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$avalanche_zones_flat(ptr))
    }

    public func avalanche_ratings() -> RustVec<Int64> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$avalanche_ratings(ptr))
    }

    public func storms_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$storms_flat(ptr))
    }

    public func tsunamis_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$tsunamis_flat(ptr))
    }

    public func tsunami_levels() -> RustVec<RustString> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$tsunami_levels(ptr))
    }

    public func spc_zones_flat() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$spc_zones_flat(ptr))
    }

    public func spc_scores() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsHazardSnapshot$spc_scores(ptr))
    }
}
extension FlowsHazardSnapshot: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FlowsHazardSnapshot$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FlowsHazardSnapshot$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FlowsHazardSnapshot) {
        __swift_bridge__$Vec_FlowsHazardSnapshot$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FlowsHazardSnapshot$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FlowsHazardSnapshot(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsHazardSnapshotRef> {
        let pointer = __swift_bridge__$Vec_FlowsHazardSnapshot$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsHazardSnapshotRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsHazardSnapshotRefMut> {
        let pointer = __swift_bridge__$Vec_FlowsHazardSnapshot$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsHazardSnapshotRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FlowsHazardSnapshotRef> {
        UnsafePointer<FlowsHazardSnapshotRef>(OpaquePointer(__swift_bridge__$Vec_FlowsHazardSnapshot$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FlowsHazardSnapshot$len(vecPtr)
    }
}



public func flows_learning_everyday_default_miles() -> Double {
    __swift_bridge__$flows_learning_everyday_default_miles()
}
public func flows_learning_everyday_floor_miles() -> Double {
    __swift_bridge__$flows_learning_everyday_floor_miles()
}
public func flows_learning_everyday_hard_cap_miles() -> Double {
    __swift_bridge__$flows_learning_everyday_hard_cap_miles()
}
public func flows_learning_everyday_min_trips_for_radius() -> Int64 {
    __swift_bridge__$flows_learning_everyday_min_trips_for_radius()
}
public func flows_learning_everyday_trip_window() -> Int64 {
    __swift_bridge__$flows_learning_everyday_trip_window()
}
public func flows_learning_everyday_max_places_per_category() -> Int64 {
    __swift_bridge__$flows_learning_everyday_max_places_per_category()
}
public func flows_learning_everyday_feature_index_space() -> Int64 {
    __swift_bridge__$flows_learning_everyday_feature_index_space()
}
public func flows_learning_everyday_feature_count() -> Int64 {
    __swift_bridge__$flows_learning_everyday_feature_count()
}
public func flows_learning_everyday_quantile(_ values: UnsafeBufferPointer<Double>, _ q: Double) -> FlowsLearningOptional {
    __swift_bridge__$flows_learning_everyday_quantile(values.toFfiSlice(), q).intoSwiftRepr()
}
public func flows_learning_everyday_radius_miles(_ trip_miles: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_learning_everyday_radius_miles(trip_miles.toFfiSlice())
}
public func flows_learning_everyday_mean_trip_miles(_ trip_miles: UnsafeBufferPointer<Double>) -> FlowsLearningOptional {
    __swift_bridge__$flows_learning_everyday_mean_trip_miles(trip_miles.toFfiSlice()).intoSwiftRepr()
}
public func flows_learning_everyday_trip_miles_sd(_ trip_miles: UnsafeBufferPointer<Double>) -> FlowsLearningOptional {
    __swift_bridge__$flows_learning_everyday_trip_miles_sd(trip_miles.toFfiSlice()).intoSwiftRepr()
}
public func flows_learning_everyday_miles(_ a_lat: Double, _ a_lon: Double, _ b_lat: Double, _ b_lon: Double) -> Double {
    __swift_bridge__$flows_learning_everyday_miles(a_lat, a_lon, b_lat, b_lon)
}
public func flows_learning_everyday_accepts_trip(_ miles: Double) -> Bool {
    __swift_bridge__$flows_learning_everyday_accepts_trip(miles)
}
public func flows_learning_everyday_hour_bucket(_ hour: Int64) -> Int64 {
    __swift_bridge__$flows_learning_everyday_hour_bucket(hour)
}
public func flows_learning_everyday_feature_index<GenericToRustStr: ToRustStr>(_ raw: GenericToRustStr) -> Int32 {
    return raw.toRustStr({ rawAsRustStr in
        __swift_bridge__$flows_learning_everyday_feature_index(rawAsRustStr)
    })
}
public func flows_learning_everyday_features(_ hour_bucket: Int64, _ weekend: Bool, _ start_lat: Double, _ start_lon: Double, _ place_lat: Double, _ place_lon: Double, _ feature_index: Int64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_learning_everyday_features(hour_bucket, weekend, start_lat, start_lon, place_lat, place_lon, feature_index))
}
public func flows_learning_everyday_ranked_order<GenericToRustStr: ToRustStr>(_ uses: UnsafeBufferPointer<Int64>, _ seen: UnsafeBufferPointer<Int64>, _ last_used: UnsafeBufferPointer<Double>, _ names_joined: GenericToRustStr) -> RustVec<Double> {
    return names_joined.toRustStr({ names_joinedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_learning_everyday_ranked_order(uses.toFfiSlice(), seen.toFfiSlice(), last_used.toFfiSlice(), names_joinedAsRustStr))
    })
}
public func flows_learning_everyday_evict_index(_ uses: UnsafeBufferPointer<Int64>, _ seen: UnsafeBufferPointer<Int64>, _ last_used: UnsafeBufferPointer<Double>) -> Int32 {
    __swift_bridge__$flows_learning_everyday_evict_index(uses.toFfiSlice(), seen.toFfiSlice(), last_used.toFfiSlice())
}
public func flows_learning_decay_plan(_ last_decay: Double, _ now: Double, _ half_life_seconds: Double) -> FlowsLearningDecay {
    __swift_bridge__$flows_learning_decay_plan(last_decay, now, half_life_seconds).intoSwiftRepr()
}
public func flows_learning_traffic_half_life_seconds() -> Double {
    __swift_bridge__$flows_learning_traffic_half_life_seconds()
}
public func flows_learning_traffic_confident_after() -> Int64 {
    __swift_bridge__$flows_learning_traffic_confident_after()
}
public func flows_learning_traffic_max_factor() -> Double {
    __swift_bridge__$flows_learning_traffic_max_factor()
}
public func flows_learning_traffic_min_factor() -> Double {
    __swift_bridge__$flows_learning_traffic_min_factor()
}
public func flows_learning_traffic_weather_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_learning_traffic_weather_names())
}
public func flows_learning_traffic_weather_from_family<GenericToRustStr: ToRustStr>(_ family: GenericToRustStr, _ has_family: Bool) -> UInt8 {
    return family.toRustStr({ familyAsRustStr in
        __swift_bridge__$flows_learning_traffic_weather_from_family(familyAsRustStr, has_family)
    })
}
public func flows_learning_road_class_is_highway(_ average_mph: Double) -> Bool {
    __swift_bridge__$flows_learning_road_class_is_highway(average_mph)
}
public func flows_learning_delay_cell_mean(_ weighted_sum: Double, _ weight: Double) -> Double {
    __swift_bridge__$flows_learning_delay_cell_mean(weighted_sum, weight)
}
public func flows_learning_traffic_accepts(_ predicted_seconds: Double, _ actual_seconds: Double) -> Bool {
    __swift_bridge__$flows_learning_traffic_accepts(predicted_seconds, actual_seconds)
}
public func flows_learning_traffic_add(_ weighted_sum: Double, _ weight: Double, _ count: Int64, _ predicted_seconds: Double, _ actual_seconds: Double) -> FlowsLearningCellUpdate {
    __swift_bridge__$flows_learning_traffic_add(weighted_sum, weight, count, predicted_seconds, actual_seconds).intoSwiftRepr()
}
public func flows_learning_traffic_factor(_ is_highway: Bool, _ local: FlowsLearningCell, _ has_local: Bool, _ pooled: FlowsLearningCell, _ has_pooled: Bool) -> Double {
    __swift_bridge__$flows_learning_traffic_factor(is_highway, local.intoFfiRepr(), has_local, pooled.intoFfiRepr(), has_pooled)
}
public func flows_learning_traffic_adjusted_seconds(_ router_seconds: Double, _ is_highway: Bool, _ local: FlowsLearningCell, _ has_local: Bool, _ pooled: FlowsLearningCell, _ has_pooled: Bool) -> Double {
    __swift_bridge__$flows_learning_traffic_adjusted_seconds(router_seconds, is_highway, local.intoFfiRepr(), has_local, pooled.intoFfiRepr(), has_pooled)
}
public func flows_learning_traffic_delay_minutes(_ router_seconds: Double, _ is_highway: Bool, _ local: FlowsLearningCell, _ has_local: Bool, _ pooled: FlowsLearningCell, _ has_pooled: Bool) -> FlowsLearningOptional {
    __swift_bridge__$flows_learning_traffic_delay_minutes(router_seconds, is_highway, local.intoFfiRepr(), has_local, pooled.intoFfiRepr(), has_pooled).intoSwiftRepr()
}
public func flows_learning_traffic_is_confident(_ count: Int64) -> Bool {
    __swift_bridge__$flows_learning_traffic_is_confident(count)
}
public func flows_learning_efficiency_half_life_seconds() -> Double {
    __swift_bridge__$flows_learning_efficiency_half_life_seconds()
}
public func flows_learning_efficiency_confident_miles() -> Double {
    __swift_bridge__$flows_learning_efficiency_confident_miles()
}
public func flows_learning_efficiency_min_ratio() -> Double {
    __swift_bridge__$flows_learning_efficiency_min_ratio()
}
public func flows_learning_efficiency_max_ratio() -> Double {
    __swift_bridge__$flows_learning_efficiency_max_ratio()
}
public func flows_learning_efficiency_cell_mean(_ weighted_sum: Double, _ weight: Double) -> Double {
    __swift_bridge__$flows_learning_efficiency_cell_mean(weighted_sum, weight)
}
public func flows_learning_efficiency_accepts(_ miles_driven: Double, _ units_burned: Double) -> Bool {
    __swift_bridge__$flows_learning_efficiency_accepts(miles_driven, units_burned)
}
public func flows_learning_efficiency_add(_ weighted_sum: Double, _ weight: Double, _ miles: Double, _ miles_driven: Double, _ units_burned: Double) -> FlowsLearningCell {
    __swift_bridge__$flows_learning_efficiency_add(weighted_sum, weight, miles, miles_driven, units_burned).intoSwiftRepr()
}
public func flows_learning_efficiency_economy(_ rated_miles_per_unit: Double, _ is_highway: Bool, _ local: FlowsLearningCell, _ has_local: Bool, _ pooled: FlowsLearningCell, _ has_pooled: Bool) -> Double {
    __swift_bridge__$flows_learning_efficiency_economy(rated_miles_per_unit, is_highway, local.intoFfiRepr(), has_local, pooled.intoFfiRepr(), has_pooled)
}
public func flows_learning_efficiency_is_confident(_ miles: Double) -> Bool {
    __swift_bridge__$flows_learning_efficiency_is_confident(miles)
}
public func flows_learning_buffer_alpha() -> Double {
    __swift_bridge__$flows_learning_buffer_alpha()
}
public func flows_learning_buffer_min_samples_to_trust() -> Int64 {
    __swift_bridge__$flows_learning_buffer_min_samples_to_trust()
}
public func flows_learning_buffer_plausible_low() -> Double {
    __swift_bridge__$flows_learning_buffer_plausible_low()
}
public func flows_learning_buffer_plausible_high() -> Double {
    __swift_bridge__$flows_learning_buffer_plausible_high()
}
public func flows_learning_buffer_is_usable(_ sample: Double) -> Bool {
    __swift_bridge__$flows_learning_buffer_is_usable(sample)
}
public func flows_learning_buffer_updated(_ mean: Double, _ has_mean: Bool, _ sample: Double) -> FlowsLearningOptional {
    __swift_bridge__$flows_learning_buffer_updated(mean, has_mean, sample).intoSwiftRepr()
}
public func flows_learning_buffer_wait_seconds(_ prior: Double, _ learned_mean: Double, _ has_mean: Bool, _ samples: Int64) -> Double {
    __swift_bridge__$flows_learning_buffer_wait_seconds(prior, learned_mean, has_mean, samples)
}
public func flows_learning_refuel_accuracy_floor() -> Double {
    __swift_bridge__$flows_learning_refuel_accuracy_floor()
}
public func flows_learning_refuel_window() -> Int64 {
    __swift_bridge__$flows_learning_refuel_window()
}
public func flows_learning_refuel_retained() -> Int64 {
    __swift_bridge__$flows_learning_refuel_retained()
}
public func flows_learning_stale_gauge_gap_seconds() -> Double {
    __swift_bridge__$flows_learning_stale_gauge_gap_seconds()
}
public func flows_learning_refuel_accuracy(_ errors: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_learning_refuel_accuracy(errors.toFfiSlice())
}
public func flows_learning_refuel_error(_ predicted_fraction: Double, _ reported_fraction: Double) -> Double {
    __swift_bridge__$flows_learning_refuel_error(predicted_fraction, reported_fraction)
}
public func flows_learning_refuel_should_prompt(_ check_ins_enabled: Bool, _ accuracy: Double) -> Bool {
    __swift_bridge__$flows_learning_refuel_should_prompt(check_ins_enabled, accuracy)
}
public func flows_learning_gauge_went_stale(_ last_used: Double, _ has_last_used: Bool, _ now: Double) -> Bool {
    __swift_bridge__$flows_learning_gauge_went_stale(last_used, has_last_used, now)
}
public func flows_learning_eta_min_plausible_ratio() -> Double {
    __swift_bridge__$flows_learning_eta_min_plausible_ratio()
}
public func flows_learning_eta_max_plausible_ratio() -> Double {
    __swift_bridge__$flows_learning_eta_max_plausible_ratio()
}
public func flows_learning_eta_min_samples_to_apply() -> Int64 {
    __swift_bridge__$flows_learning_eta_min_samples_to_apply()
}
public func flows_learning_eta_min_meaningful_deviation() -> Double {
    __swift_bridge__$flows_learning_eta_min_meaningful_deviation()
}
public func flows_learning_eta_clamp_low() -> Double {
    __swift_bridge__$flows_learning_eta_clamp_low()
}
public func flows_learning_eta_clamp_high() -> Double {
    __swift_bridge__$flows_learning_eta_clamp_high()
}
public func flows_learning_eta_multiplier(_ log_ratio: Double, _ samples: Int64) -> Double {
    __swift_bridge__$flows_learning_eta_multiplier(log_ratio, samples)
}
public func flows_learning_eta_record(_ log_ratio: Double, _ samples: Int64, _ predicted_seconds: Double, _ actual_seconds: Double, _ stopped_seconds: Double) -> FlowsLearningEta {
    __swift_bridge__$flows_learning_eta_record(log_ratio, samples, predicted_seconds, actual_seconds, stopped_seconds).intoSwiftRepr()
}
public func flows_learning_destination_recency_half_life_days() -> Double {
    __swift_bridge__$flows_learning_destination_recency_half_life_days()
}
public func flows_learning_destination_context_weight() -> Double {
    __swift_bridge__$flows_learning_destination_context_weight()
}
public func flows_learning_destination_time_weight() -> Double {
    __swift_bridge__$flows_learning_destination_time_weight()
}
public func flows_learning_destination_base_weight() -> Double {
    __swift_bridge__$flows_learning_destination_base_weight()
}
public func flows_learning_destination_reason(_ context_hits: Int64, _ time_hits: Int64, _ total_hits: Int64) -> UInt8 {
    __swift_bridge__$flows_learning_destination_reason(context_hits, time_hits, total_hits)
}
public func flows_learning_destination_rank(_ context_hits: UnsafeBufferPointer<Int64>, _ time_hits: UnsafeBufferPointer<Int64>, _ total_hits: UnsafeBufferPointer<Int64>, _ last_used: UnsafeBufferPointer<Double>, _ now: Double, _ limit: Int64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_learning_destination_rank(context_hits.toFfiSlice(), time_hits.toFfiSlice(), total_hits.toFfiSlice(), last_used.toFfiSlice(), now, limit))
}
public func flows_learning_destination_is_confident(_ top_score: Double, _ has_top: Bool, _ minimum_evidence: Int64) -> Bool {
    __swift_bridge__$flows_learning_destination_is_confident(top_score, has_top, minimum_evidence)
}
public struct FlowsLearningOptional {
    public var is_some: Double
    public var value: Double

    public init(is_some: Double,value: Double) {
        self.is_some = is_some
        self.value = value
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsLearningOptional {
        { let val = self; return __swift_bridge__$FlowsLearningOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$FlowsLearningOptional {
    @inline(__always)
    func intoSwiftRepr() -> FlowsLearningOptional {
        { let val = self; return FlowsLearningOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$Option$FlowsLearningOptional {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsLearningOptional> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsLearningOptional>) -> __swift_bridge__$Option$FlowsLearningOptional {
        if let v = val {
            return __swift_bridge__$Option$FlowsLearningOptional(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsLearningOptional(is_some: false, val: __swift_bridge__$FlowsLearningOptional())
        }
    }
}
public struct FlowsLearningCell {
    public var weighted_sum: Double
    public var weight: Double
    public var count: Double

    public init(weighted_sum: Double,weight: Double,count: Double) {
        self.weighted_sum = weighted_sum
        self.weight = weight
        self.count = count
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsLearningCell {
        { let val = self; return __swift_bridge__$FlowsLearningCell(weighted_sum: val.weighted_sum, weight: val.weight, count: val.count); }()
    }
}
extension __swift_bridge__$FlowsLearningCell {
    @inline(__always)
    func intoSwiftRepr() -> FlowsLearningCell {
        { let val = self; return FlowsLearningCell(weighted_sum: val.weighted_sum, weight: val.weight, count: val.count); }()
    }
}
extension __swift_bridge__$Option$FlowsLearningCell {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsLearningCell> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsLearningCell>) -> __swift_bridge__$Option$FlowsLearningCell {
        if let v = val {
            return __swift_bridge__$Option$FlowsLearningCell(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsLearningCell(is_some: false, val: __swift_bridge__$FlowsLearningCell())
        }
    }
}
public struct FlowsLearningCellUpdate {
    public var has: Double
    public var weighted_sum: Double
    public var weight: Double
    public var count: Double

    public init(has: Double,weighted_sum: Double,weight: Double,count: Double) {
        self.has = has
        self.weighted_sum = weighted_sum
        self.weight = weight
        self.count = count
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsLearningCellUpdate {
        { let val = self; return __swift_bridge__$FlowsLearningCellUpdate(has: val.has, weighted_sum: val.weighted_sum, weight: val.weight, count: val.count); }()
    }
}
extension __swift_bridge__$FlowsLearningCellUpdate {
    @inline(__always)
    func intoSwiftRepr() -> FlowsLearningCellUpdate {
        { let val = self; return FlowsLearningCellUpdate(has: val.has, weighted_sum: val.weighted_sum, weight: val.weight, count: val.count); }()
    }
}
extension __swift_bridge__$Option$FlowsLearningCellUpdate {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsLearningCellUpdate> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsLearningCellUpdate>) -> __swift_bridge__$Option$FlowsLearningCellUpdate {
        if let v = val {
            return __swift_bridge__$Option$FlowsLearningCellUpdate(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsLearningCellUpdate(is_some: false, val: __swift_bridge__$FlowsLearningCellUpdate())
        }
    }
}
public struct FlowsLearningDecay {
    public var apply: Double
    public var factor: Double
    public var last_decay: Double

    public init(apply: Double,factor: Double,last_decay: Double) {
        self.apply = apply
        self.factor = factor
        self.last_decay = last_decay
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsLearningDecay {
        { let val = self; return __swift_bridge__$FlowsLearningDecay(apply: val.apply, factor: val.factor, last_decay: val.last_decay); }()
    }
}
extension __swift_bridge__$FlowsLearningDecay {
    @inline(__always)
    func intoSwiftRepr() -> FlowsLearningDecay {
        { let val = self; return FlowsLearningDecay(apply: val.apply, factor: val.factor, last_decay: val.last_decay); }()
    }
}
extension __swift_bridge__$Option$FlowsLearningDecay {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsLearningDecay> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsLearningDecay>) -> __swift_bridge__$Option$FlowsLearningDecay {
        if let v = val {
            return __swift_bridge__$Option$FlowsLearningDecay(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsLearningDecay(is_some: false, val: __swift_bridge__$FlowsLearningDecay())
        }
    }
}
public struct FlowsLearningEta {
    public var has: Double
    public var log_ratio: Double
    public var samples: Int64

    public init(has: Double,log_ratio: Double,samples: Int64) {
        self.has = has
        self.log_ratio = log_ratio
        self.samples = samples
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsLearningEta {
        { let val = self; return __swift_bridge__$FlowsLearningEta(has: val.has, log_ratio: val.log_ratio, samples: val.samples); }()
    }
}
extension __swift_bridge__$FlowsLearningEta {
    @inline(__always)
    func intoSwiftRepr() -> FlowsLearningEta {
        { let val = self; return FlowsLearningEta(has: val.has, log_ratio: val.log_ratio, samples: val.samples); }()
    }
}
extension __swift_bridge__$Option$FlowsLearningEta {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsLearningEta> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsLearningEta>) -> __swift_bridge__$Option$FlowsLearningEta {
        if let v = val {
            return __swift_bridge__$Option$FlowsLearningEta(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsLearningEta(is_some: false, val: __swift_bridge__$FlowsLearningEta())
        }
    }
}


public func flows_long_trips_fuel_severity(_ fraction: Double) -> Double {
    __swift_bridge__$flows_long_trips_fuel_severity(fraction)
}
public func flows_long_trips_fuel_band(_ fraction: Double) -> UInt8 {
    __swift_bridge__$flows_long_trips_fuel_band(fraction)
}
public func flows_long_trips_warn_at_reachable_count() -> Int64 {
    __swift_bridge__$flows_long_trips_warn_at_reachable_count()
}
public func flows_long_trips_reachable_stations(_ miles: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ priced: UnsafeBufferPointer<UInt8>, _ count: Int64, _ range_miles: Double, _ reserve_miles: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_reachable_stations(miles.toFfiSlice(), prices.toFfiSlice(), priced.toFfiSlice(), count, range_miles, reserve_miles))
}
public func flows_long_trips_fuel_level(_ miles: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ priced: UnsafeBufferPointer<UInt8>, _ count: Int64, _ range_miles: Double, _ reserve_miles: Double) -> Int64 {
    __swift_bridge__$flows_long_trips_fuel_level(miles.toFfiSlice(), prices.toFfiSlice(), priced.toFfiSlice(), count, range_miles, reserve_miles)
}
public func flows_long_trips_cheapest_station(_ miles: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ priced: UnsafeBufferPointer<UInt8>, _ count: Int64, _ range_miles: Double, _ reserve_miles: Double) -> Int64 {
    __swift_bridge__$flows_long_trips_cheapest_station(miles.toFfiSlice(), prices.toFfiSlice(), priced.toFfiSlice(), count, range_miles, reserve_miles)
}
public func flows_long_trips_should_offer_share(_ route_meters: Double, _ driven_today_meters: Double) -> Bool {
    __swift_bridge__$flows_long_trips_should_offer_share(route_meters, driven_today_meters)
}
public func flows_long_trips_share_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_share_constants())
}
public func flows_long_trips_share_caps() -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_share_caps())
}
public func flows_long_trips_daily_drive_add(_ day: Double, _ meters: Double, _ today: Double, _ delta: Double) -> FlowsLongTripsDay {
    __swift_bridge__$flows_long_trips_daily_drive_add(day, meters, today, delta).intoSwiftRepr()
}
public func flows_long_trips_ranked_recipients(_ dates: UnsafeBufferPointer<Double>, _ date_counts: UnsafeBufferPointer<Int64>, _ recipient_count: Int64, _ now: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_ranked_recipients(dates.toFfiSlice(), date_counts.toFfiSlice(), recipient_count, now))
}
public func flows_long_trips_normalized_phone<GenericToRustStr: ToRustStr>(_ phone: GenericToRustStr) -> RustString {
    return phone.toRustStr({ phoneAsRustStr in
        RustString(ptr: __swift_bridge__$flows_long_trips_normalized_phone(phoneAsRustStr))
    })
}
public func flows_long_trips_record_share<GenericToRustStr: ToRustStr>(_ phones: GenericToRustStr, _ phone_lengths: UnsafeBufferPointer<Int64>, _ dates: UnsafeBufferPointer<Double>, _ date_counts: UnsafeBufferPointer<Int64>, _ recipient_count: Int64, _ name: GenericToRustStr, _ phone: GenericToRustStr, _ date: Double) -> RustVec<Int64> {
    return phone.toRustStr({ phoneAsRustStr in
        return name.toRustStr({ nameAsRustStr in
        return phones.toRustStr({ phonesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_long_trips_record_share(phonesAsRustStr, phone_lengths.toFfiSlice(), dates.toFfiSlice(), date_counts.toFfiSlice(), recipient_count, nameAsRustStr, phoneAsRustStr, date))
    })
    })
    })
}
public func flows_long_trips_corridor_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_corridor_constants())
}
public func flows_long_trips_corridor_limits() -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_corridor_limits())
}
public func flows_long_trips_keep_corridor(_ saved_at: Double, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ count: Int64, _ now: Double, _ lat: Double, _ lon: Double, _ has_position: Bool) -> Bool {
    __swift_bridge__$flows_long_trips_keep_corridor(saved_at, lats.toFfiSlice(), lons.toFfiSlice(), count, now, lat, lon, has_position)
}
public func flows_long_trips_prune_corridors(_ saved_at: UnsafeBufferPointer<Double>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ point_counts: UnsafeBufferPointer<Int64>, _ corridor_count: Int64, _ now: Double, _ lat: Double, _ lon: Double, _ has_position: Bool) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_prune_corridors(saved_at.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), point_counts.toFfiSlice(), corridor_count, now, lat, lon, has_position))
}
public func flows_long_trips_worth_saving(_ trip_meters: Double) -> Bool {
    __swift_bridge__$flows_long_trips_worth_saving(trip_meters)
}
public func flows_long_trips_supersedes(_ newer_lat: Double, _ newer_lon: Double, _ has_newer: Bool, _ older_lat: Double, _ older_lon: Double, _ has_older: Bool) -> Bool {
    __swift_bridge__$flows_long_trips_supersedes(newer_lat, newer_lon, has_newer, older_lat, older_lon, has_older)
}
public func flows_long_trips_decimate(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ count: Int64, _ step_meters: Double, _ limit: Int64) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_decimate(lats.toFfiSlice(), lons.toFfiSlice(), count, step_meters, limit))
}
public func flows_long_trips_record_corridor(_ saved_at: UnsafeBufferPointer<Double>, _ end_lats: UnsafeBufferPointer<Double>, _ end_lons: UnsafeBufferPointer<Double>, _ has_end: UnsafeBufferPointer<UInt8>, _ corridor_count: Int64, _ new_lat: Double, _ new_lon: Double, _ has_new: Bool, _ now: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_long_trips_record_corridor(saved_at.toFfiSlice(), end_lats.toFfiSlice(), end_lons.toFfiSlice(), has_end.toFfiSlice(), corridor_count, new_lat, new_lon, has_new, now))
}
public struct FlowsLongTripsDay {
    public var day: Double
    public var meters: Double

    public init(day: Double,meters: Double) {
        self.day = day
        self.meters = meters
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsLongTripsDay {
        { let val = self; return __swift_bridge__$FlowsLongTripsDay(day: val.day, meters: val.meters); }()
    }
}
extension __swift_bridge__$FlowsLongTripsDay {
    @inline(__always)
    func intoSwiftRepr() -> FlowsLongTripsDay {
        { let val = self; return FlowsLongTripsDay(day: val.day, meters: val.meters); }()
    }
}
extension __swift_bridge__$Option$FlowsLongTripsDay {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsLongTripsDay> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsLongTripsDay>) -> __swift_bridge__$Option$FlowsLongTripsDay {
        if let v = val {
            return __swift_bridge__$Option$FlowsLongTripsDay(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsLongTripsDay(is_some: false, val: __swift_bridge__$FlowsLongTripsDay())
        }
    }
}


public func flows_modes_signal_tier<GenericToRustStr: ToRustStr>(_ radio_technology: GenericToRustStr, _ has_technology: Bool, _ on_wifi: Bool, _ offline: Bool) -> UInt8 {
    return radio_technology.toRustStr({ radio_technologyAsRustStr in
        __swift_bridge__$flows_modes_signal_tier(radio_technologyAsRustStr, has_technology, on_wifi, offline)
    })
}
public func flows_modes_should_pre_stage(_ tier: UInt8, _ buffer_draining: Bool, _ recent_stalls: Int64) -> Bool {
    __swift_bridge__$flows_modes_should_pre_stage(tier, buffer_draining, recent_stalls)
}
public func flows_modes_is_draining(_ previous: Double, _ has_previous: Bool, _ current: Double, _ has_current: Bool) -> Bool {
    __swift_bridge__$flows_modes_is_draining(previous, has_previous, current, has_current)
}
public func flows_modes_device_tier(_ cores: Int64, _ memory_gb: Double) -> UInt8 {
    __swift_bridge__$flows_modes_device_tier(cores, memory_gb)
}
public func flows_modes_tuning_settings(_ tier: UInt8, _ thermal: Int64, _ low_power: Bool) -> FlowsModesTuning {
    __swift_bridge__$flows_modes_tuning_settings(tier, thermal, low_power).intoSwiftRepr()
}
public func flows_modes_on_connection_lost<GenericToRustStr: ToRustStr>(_ is_playing: Bool, _ needs_network: Bool, _ has_local_music: Bool, _ last_genre: GenericToRustStr, _ has_genre: Bool) -> UInt8 {
    return last_genre.toRustStr({ last_genreAsRustStr in
        __swift_bridge__$flows_modes_on_connection_lost(is_playing, needs_network, has_local_music, last_genreAsRustStr, has_genre)
    })
}
public func flows_modes_fallback_genre<GenericToRustStr: ToRustStr>(_ last_genre: GenericToRustStr, _ has_genre: Bool) -> RustString {
    return last_genre.toRustStr({ last_genreAsRustStr in
        RustString(ptr: __swift_bridge__$flows_modes_fallback_genre(last_genreAsRustStr, has_genre))
    })
}
public func flows_modes_should_restore(_ handed_off: Bool, _ connection_held: Bool, _ driver_chose_since: Bool) -> Bool {
    __swift_bridge__$flows_modes_should_restore(handed_off, connection_held, driver_chose_since)
}
public func flows_modes_restore_hold_seconds() -> Double {
    __swift_bridge__$flows_modes_restore_hold_seconds()
}
public func flows_modes_grace_seconds(_ source: UInt8, _ measured_buffer: Double, _ has_buffer: Bool) -> Double {
    __swift_bridge__$flows_modes_grace_seconds(source, measured_buffer, has_buffer)
}
public func flows_modes_grace_caps() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_grace_caps())
}
public func flows_modes_nearest_station(_ lat: Double, _ lon: Double, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ exact: UnsafeBufferPointer<UInt8>) -> FlowsModesNearest {
    __swift_bridge__$flows_modes_nearest_station(lat, lon, lats.toFfiSlice(), lons.toFfiSlice(), exact.toFfiSlice()).intoSwiftRepr()
}
public func flows_modes_retarget<GenericToRustStr: ToRustStr>(_ playing_id: GenericToRustStr, _ playing_lat: Double, _ playing_lon: Double, _ has_playing_coordinate: Bool, _ lat: Double, _ lon: Double, _ ids_joined: GenericToRustStr, _ id_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ exact: UnsafeBufferPointer<UInt8>) -> Int64 {
    return ids_joined.toRustStr({ ids_joinedAsRustStr in
        return playing_id.toRustStr({ playing_idAsRustStr in
        __swift_bridge__$flows_modes_retarget(playing_idAsRustStr, playing_lat, playing_lon, has_playing_coordinate, lat, lon, ids_joinedAsRustStr, id_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), exact.toFfiSlice())
    })
    })
}
public func flows_modes_switch_margin() -> Double {
    __swift_bridge__$flows_modes_switch_margin()
}
public func flows_modes_nearest_within(_ lat: Double, _ lon: Double, _ max_meters: Double, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) -> Int64 {
    __swift_bridge__$flows_modes_nearest_within(lat, lon, max_meters, lats.toFfiSlice(), lons.toFfiSlice())
}
public func flows_modes_should_record(_ lat: Double, _ lon: Double, _ last_lat: Double, _ last_lon: Double, _ has_last: Bool) -> Bool {
    __swift_bridge__$flows_modes_should_record(lat, lon, last_lat, last_lon, has_last)
}
public func flows_modes_way_back_meters(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_modes_way_back_meters(lats.toFfiSlice(), lons.toFfiSlice())
}
public func flows_modes_min_step_meters() -> Double {
    __swift_bridge__$flows_modes_min_step_meters()
}
public func flows_modes_max_points() -> Int64 {
    __swift_bridge__$flows_modes_max_points()
}
public func flows_modes_worth_flying(_ trip_miles: Double) -> Bool {
    __swift_bridge__$flows_modes_worth_flying(trip_miles)
}
public func flows_modes_flight_seconds(_ airport_miles: Double) -> Double {
    __swift_bridge__$flows_modes_flight_seconds(airport_miles)
}
public func flows_modes_door_seconds(_ airport_miles: Double) -> Double {
    __swift_bridge__$flows_modes_door_seconds(airport_miles)
}
public func flows_modes_fare_estimate(_ airport_miles: Double) -> Double {
    __swift_bridge__$flows_modes_fare_estimate(airport_miles)
}
public func flows_modes_airport_score<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> Int64 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_modes_airport_score(nameAsRustStr)
    })
}
public func flows_modes_pick_airport<GenericToRustStr: ToRustStr>(_ names_joined: GenericToRustStr, _ name_lens: UnsafeBufferPointer<Int64>, _ meters: UnsafeBufferPointer<Double>, _ max_meters: Double) -> Int64 {
    return names_joined.toRustStr({ names_joinedAsRustStr in
        __swift_bridge__$flows_modes_pick_airport(names_joinedAsRustStr, name_lens.toFfiSlice(), meters.toFfiSlice(), max_meters)
    })
}
public func flows_modes_air_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_air_constants())
}
public func flows_modes_is_peak(_ local_minutes: Int64) -> Bool {
    __swift_bridge__$flows_modes_is_peak(local_minutes)
}
public func flows_modes_local_minutes(_ reference_seconds: Double, _ longitude: Double) -> FlowsModesMinutes {
    __swift_bridge__$flows_modes_local_minutes(reference_seconds, longitude).intoSwiftRepr()
}
public func flows_modes_traffic_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_traffic_constants())
}
public func flows_modes_risk_clusters(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ adjacency_meters: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_modes_risk_clusters(lats.toFfiSlice(), lons.toFfiSlice(), adjacency_meters))
}
public func flows_modes_risk_hull(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ count: Int64, _ pad_meters: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_risk_hull(lats.toFfiSlice(), lons.toFfiSlice(), count, pad_meters))
}
public func flows_modes_amtrak_fare(_ miles: Double) -> Double {
    __swift_bridge__$flows_modes_amtrak_fare(miles)
}
public func flows_modes_greyhound_fare(_ miles: Double) -> Double {
    __swift_bridge__$flows_modes_greyhound_fare(miles)
}
public func flows_modes_local_fares() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_local_fares())
}
public func flows_modes_ride_cost(_ miles: Double) -> Double {
    __swift_bridge__$flows_modes_ride_cost(miles)
}
public func flows_modes_meets_bar(_ walk_alone_seconds: Double, _ total_seconds: Double, _ cost_usd: Double) -> Bool {
    __swift_bridge__$flows_modes_meets_bar(walk_alone_seconds, total_seconds, cost_usd)
}
public func flows_modes_evaluate_ride(_ walk_alone_seconds: Double, _ drive_seconds: Double, _ trip_miles: Double) -> FlowsModesRideOffer {
    __swift_bridge__$flows_modes_evaluate_ride(walk_alone_seconds, drive_seconds, trip_miles).intoSwiftRepr()
}
public func flows_modes_prefix_coordinates(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ meters: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_prefix_coordinates(lats.toFfiSlice(), lons.toFfiSlice(), meters))
}
public func flows_modes_ride_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_modes_ride_constants())
}
public struct FlowsModesTuning {
    public var max_in_flight: Int64
    public var planning_max_in_flight: Int64
    public var viewport_grid_span: Int64
    public var ttl_multiplier: Double
    public var debounce_seconds: Double

    public init(max_in_flight: Int64,planning_max_in_flight: Int64,viewport_grid_span: Int64,ttl_multiplier: Double,debounce_seconds: Double) {
        self.max_in_flight = max_in_flight
        self.planning_max_in_flight = planning_max_in_flight
        self.viewport_grid_span = viewport_grid_span
        self.ttl_multiplier = ttl_multiplier
        self.debounce_seconds = debounce_seconds
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsModesTuning {
        { let val = self; return __swift_bridge__$FlowsModesTuning(max_in_flight: val.max_in_flight, planning_max_in_flight: val.planning_max_in_flight, viewport_grid_span: val.viewport_grid_span, ttl_multiplier: val.ttl_multiplier, debounce_seconds: val.debounce_seconds); }()
    }
}
extension __swift_bridge__$FlowsModesTuning {
    @inline(__always)
    func intoSwiftRepr() -> FlowsModesTuning {
        { let val = self; return FlowsModesTuning(max_in_flight: val.max_in_flight, planning_max_in_flight: val.planning_max_in_flight, viewport_grid_span: val.viewport_grid_span, ttl_multiplier: val.ttl_multiplier, debounce_seconds: val.debounce_seconds); }()
    }
}
extension __swift_bridge__$Option$FlowsModesTuning {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsModesTuning> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsModesTuning>) -> __swift_bridge__$Option$FlowsModesTuning {
        if let v = val {
            return __swift_bridge__$Option$FlowsModesTuning(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsModesTuning(is_some: false, val: __swift_bridge__$FlowsModesTuning())
        }
    }
}
public struct FlowsModesNearest {
    public var has: Bool
    public var index: Int64
    public var meters: Double

    public init(has: Bool,index: Int64,meters: Double) {
        self.has = has
        self.index = index
        self.meters = meters
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsModesNearest {
        { let val = self; return __swift_bridge__$FlowsModesNearest(has: val.has, index: val.index, meters: val.meters); }()
    }
}
extension __swift_bridge__$FlowsModesNearest {
    @inline(__always)
    func intoSwiftRepr() -> FlowsModesNearest {
        { let val = self; return FlowsModesNearest(has: val.has, index: val.index, meters: val.meters); }()
    }
}
extension __swift_bridge__$Option$FlowsModesNearest {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsModesNearest> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsModesNearest>) -> __swift_bridge__$Option$FlowsModesNearest {
        if let v = val {
            return __swift_bridge__$Option$FlowsModesNearest(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsModesNearest(is_some: false, val: __swift_bridge__$FlowsModesNearest())
        }
    }
}
public struct FlowsModesMinutes {
    public var has: Bool
    public var minutes: Int64
    public var interval_seconds: Double

    public init(has: Bool,minutes: Int64,interval_seconds: Double) {
        self.has = has
        self.minutes = minutes
        self.interval_seconds = interval_seconds
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsModesMinutes {
        { let val = self; return __swift_bridge__$FlowsModesMinutes(has: val.has, minutes: val.minutes, interval_seconds: val.interval_seconds); }()
    }
}
extension __swift_bridge__$FlowsModesMinutes {
    @inline(__always)
    func intoSwiftRepr() -> FlowsModesMinutes {
        { let val = self; return FlowsModesMinutes(has: val.has, minutes: val.minutes, interval_seconds: val.interval_seconds); }()
    }
}
extension __swift_bridge__$Option$FlowsModesMinutes {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsModesMinutes> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsModesMinutes>) -> __swift_bridge__$Option$FlowsModesMinutes {
        if let v = val {
            return __swift_bridge__$Option$FlowsModesMinutes(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsModesMinutes(is_some: false, val: __swift_bridge__$FlowsModesMinutes())
        }
    }
}
public struct FlowsModesRideOffer {
    public var has: Bool
    public var ride_miles: Double
    public var ride_seconds: Double
    public var walk_seconds: Double
    public var cost_usd: Double

    public init(has: Bool,ride_miles: Double,ride_seconds: Double,walk_seconds: Double,cost_usd: Double) {
        self.has = has
        self.ride_miles = ride_miles
        self.ride_seconds = ride_seconds
        self.walk_seconds = walk_seconds
        self.cost_usd = cost_usd
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsModesRideOffer {
        { let val = self; return __swift_bridge__$FlowsModesRideOffer(has: val.has, ride_miles: val.ride_miles, ride_seconds: val.ride_seconds, walk_seconds: val.walk_seconds, cost_usd: val.cost_usd); }()
    }
}
extension __swift_bridge__$FlowsModesRideOffer {
    @inline(__always)
    func intoSwiftRepr() -> FlowsModesRideOffer {
        { let val = self; return FlowsModesRideOffer(has: val.has, ride_miles: val.ride_miles, ride_seconds: val.ride_seconds, walk_seconds: val.walk_seconds, cost_usd: val.cost_usd); }()
    }
}
extension __swift_bridge__$Option$FlowsModesRideOffer {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsModesRideOffer> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsModesRideOffer>) -> __swift_bridge__$Option$FlowsModesRideOffer {
        if let v = val {
            return __swift_bridge__$Option$FlowsModesRideOffer(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsModesRideOffer(is_some: false, val: __swift_bridge__$FlowsModesRideOffer())
        }
    }
}


public func flows_places_route_path(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) -> FlowsRoutePath {
    FlowsRoutePath(ptr: __swift_bridge__$flows_places_route_path(lats.toFfiSlice(), lons.toFfiSlice()))
}
public func flows_places_route_path_empty() -> FlowsRoutePath {
    FlowsRoutePath(ptr: __swift_bridge__$flows_places_route_path_empty())
}
public func flows_places_route_decimation_step(_ count: Int64) -> Int64 {
    __swift_bridge__$flows_places_route_decimation_step(count)
}
public func flows_places_admissible(_ ahead_meters: Double, _ detour_meters: Double, _ max_detour: Double) -> Bool {
    __swift_bridge__$flows_places_admissible(ahead_meters, detour_meters, max_detour)
}
public func flows_places_rank_food(_ ahead: UnsafeBufferPointer<Double>, _ detour: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ has_price: UnsafeBufferPointer<UInt8>, _ ratings: UnsafeBufferPointer<Double>, _ has_rating: UnsafeBufferPointer<UInt8>, _ max_detour: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_rank_food(ahead.toFfiSlice(), detour.toFfiSlice(), prices.toFfiSlice(), has_price.toFfiSlice(), ratings.toFfiSlice(), has_rating.toFfiSlice(), max_detour))
}
public func flows_places_rank_fuel(_ ahead: UnsafeBufferPointer<Double>, _ detour: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ has_price: UnsafeBufferPointer<UInt8>, _ ratings: UnsafeBufferPointer<Double>, _ has_rating: UnsafeBufferPointer<UInt8>, _ fill_units: Double, _ average_price_per_unit: Double, _ max_detour: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_rank_fuel(ahead.toFfiSlice(), detour.toFfiSlice(), prices.toFfiSlice(), has_price.toFfiSlice(), ratings.toFfiSlice(), has_rating.toFfiSlice(), fill_units, average_price_per_unit, max_detour))
}
public func flows_places_rank_hotels(_ ahead: UnsafeBufferPointer<Double>, _ detour: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ has_price: UnsafeBufferPointer<UInt8>, _ ratings: UnsafeBufferPointer<Double>, _ has_rating: UnsafeBufferPointer<UInt8>, _ average_nightly: Double, _ max_detour: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_rank_hotels(ahead.toFfiSlice(), detour.toFfiSlice(), prices.toFfiSlice(), has_price.toFfiSlice(), ratings.toFfiSlice(), has_rating.toFfiSlice(), average_nightly, max_detour))
}
public func flows_places_rank_parking(_ ahead: UnsafeBufferPointer<Double>, _ detour: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ has_price: UnsafeBufferPointer<UInt8>, _ ratings: UnsafeBufferPointer<Double>, _ has_rating: UnsafeBufferPointer<UInt8>, _ cost_tiers: UnsafeBufferPointer<Int64>, _ max_detour: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_rank_parking(ahead.toFfiSlice(), detour.toFfiSlice(), prices.toFfiSlice(), has_price.toFfiSlice(), ratings.toFfiSlice(), has_rating.toFfiSlice(), cost_tiers.toFfiSlice(), max_detour))
}
public func flows_places_rank_stores(_ ahead: UnsafeBufferPointer<Double>, _ detour: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ has_price: UnsafeBufferPointer<UInt8>, _ ratings: UnsafeBufferPointer<Double>, _ has_rating: UnsafeBufferPointer<UInt8>, _ market_ranks: UnsafeBufferPointer<Int64>, _ max_detour: Double) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_rank_stores(ahead.toFfiSlice(), detour.toFfiSlice(), prices.toFfiSlice(), has_price.toFfiSlice(), ratings.toFfiSlice(), has_rating.toFfiSlice(), market_ranks.toFfiSlice(), max_detour))
}
public func flows_places_parking_cost_tier<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool) -> Int64 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_parking_cost_tier(nameAsRustStr, has_name)
    })
}
public func flows_places_store_market_share_rank<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool) -> Int64 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_store_market_share_rank(nameAsRustStr, has_name)
    })
}
public func flows_places_store_market_share_order() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_places_store_market_share_order())
}
public func flows_places_fuel_fill_units(_ fuel: UInt8) -> Double {
    __swift_bridge__$flows_places_fuel_fill_units(fuel)
}
public func flows_places_fuel_average_price(_ fuel: UInt8) -> Double {
    __swift_bridge__$flows_places_fuel_average_price(fuel)
}
public func flows_places_limits() -> FlowsPlacesLimits {
    __swift_bridge__$flows_places_limits().intoSwiftRepr()
}
public func flows_places_kind_policy(_ kind: UInt8) -> FlowsPlacesKindPolicy {
    __swift_bridge__$flows_places_kind_policy(kind).intoSwiftRepr()
}
public func flows_places_search_center_cap(_ query_count: Int64) -> Int64 {
    __swift_bridge__$flows_places_search_center_cap(query_count)
}
public func flows_places_center_picks(_ count: Int64, _ cap: Int64) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_center_picks(count, cap))
}
public func flows_places_first_nearest(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double) -> Int64 {
    __swift_bridge__$flows_places_first_nearest(lats.toFfiSlice(), lons.toFfiSlice(), lat, lon)
}
public func flows_places_rank_by_distance(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ lat: Double, _ lon: Double, _ limit: Int64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_places_rank_by_distance(lats.toFfiSlice(), lons.toFfiSlice(), lat, lon, limit))
}
public func flows_places_attribute_id<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ latitude: Double, _ longitude: Double) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_places_attribute_id(nameAsRustStr, latitude, longitude))
    })
}
public func flows_places_dedup<GenericToRustStr: ToRustStr>(_ location_only: Bool, _ names_joined: GenericToRustStr, _ name_lens: UnsafeBufferPointer<Int64>, _ name_present: UnsafeBufferPointer<UInt8>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>) -> RustVec<Int64> {
    return names_joined.toRustStr({ names_joinedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_places_dedup(location_only, names_joinedAsRustStr, name_lens.toFfiSlice(), name_present.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice()))
    })
}
public func flows_places_pinned<GenericToRustStr: ToRustStr>(_ keys_joined: GenericToRustStr, _ key_lens: UnsafeBufferPointer<Int64>, _ everyday_count: Int64, _ closed_count: Int64, _ ranked_count: Int64) -> RustVec<Int64> {
    return keys_joined.toRustStr({ keys_joinedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_places_pinned(keys_joinedAsRustStr, key_lens.toFfiSlice(), everyday_count, closed_count, ranked_count))
    })
}
public func flows_places_merge<GenericToRustStr: ToRustStr>(_ keys_joined: GenericToRustStr, _ key_lens: UnsafeBufferPointer<Int64>, _ everyday_count: Int64, _ network_count: Int64) -> RustVec<Int64> {
    return keys_joined.toRustStr({ keys_joinedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_places_merge(keys_joinedAsRustStr, key_lens.toFfiSlice(), everyday_count, network_count))
    })
}
public func flows_places_shower_brand<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> UInt8 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_shower_brand(nameAsRustStr)
    })
}
public func flows_places_index_parse(_ data: UnsafeBufferPointer<UInt8>) -> Optional<FlowsPlacesIndex> {
    { let val = __swift_bridge__$flows_places_index_parse(data.toFfiSlice()); if val != nil { return FlowsPlacesIndex(ptr: val!) } else { return nil } }()
}
public func flows_places_cell_key(_ lat5: Int64, _ lon5: Int64) -> FlowsPlacesCellKey {
    __swift_bridge__$flows_places_cell_key(lat5, lon5).intoSwiftRepr()
}
public struct FlowsPlacesNearest {
    public var has: Bool
    public var index: Int64
    public var off_route: Double

    public init(has: Bool,index: Int64,off_route: Double) {
        self.has = has
        self.index = index
        self.off_route = off_route
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsPlacesNearest {
        { let val = self; return __swift_bridge__$FlowsPlacesNearest(has: val.has, index: val.index, off_route: val.off_route); }()
    }
}
extension __swift_bridge__$FlowsPlacesNearest {
    @inline(__always)
    func intoSwiftRepr() -> FlowsPlacesNearest {
        { let val = self; return FlowsPlacesNearest(has: val.has, index: val.index, off_route: val.off_route); }()
    }
}
extension __swift_bridge__$Option$FlowsPlacesNearest {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsPlacesNearest> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsPlacesNearest>) -> __swift_bridge__$Option$FlowsPlacesNearest {
        if let v = val {
            return __swift_bridge__$Option$FlowsPlacesNearest(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsPlacesNearest(is_some: false, val: __swift_bridge__$FlowsPlacesNearest())
        }
    }
}
public struct FlowsPlacesCellKey {
    public var has: Bool
    public var key: Int64

    public init(has: Bool,key: Int64) {
        self.has = has
        self.key = key
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsPlacesCellKey {
        { let val = self; return __swift_bridge__$FlowsPlacesCellKey(has: val.has, key: val.key); }()
    }
}
extension __swift_bridge__$FlowsPlacesCellKey {
    @inline(__always)
    func intoSwiftRepr() -> FlowsPlacesCellKey {
        { let val = self; return FlowsPlacesCellKey(has: val.has, key: val.key); }()
    }
}
extension __swift_bridge__$Option$FlowsPlacesCellKey {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsPlacesCellKey> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsPlacesCellKey>) -> __swift_bridge__$Option$FlowsPlacesCellKey {
        if let v = val {
            return __swift_bridge__$Option$FlowsPlacesCellKey(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsPlacesCellKey(is_some: false, val: __swift_bridge__$FlowsPlacesCellKey())
        }
    }
}
public struct FlowsPlacesKindPolicy {
    public var has: Bool
    public var max_detour_meters: Double
    public var max_detour_trucker_meters: Double
    public var region_meters: Double
    public var shard_groups: UInt32
    public var closed_fallback: Bool
    public var empty_fallback: Bool
    public var habit_pins: Bool
    public var nearest_leads: Bool
    public var ratings_lookup: Bool
    public var brand_cost_tier: Bool
    public var shower_ladder: Bool
    public var location_dedup: Bool

    public init(has: Bool,max_detour_meters: Double,max_detour_trucker_meters: Double,region_meters: Double,shard_groups: UInt32,closed_fallback: Bool,empty_fallback: Bool,habit_pins: Bool,nearest_leads: Bool,ratings_lookup: Bool,brand_cost_tier: Bool,shower_ladder: Bool,location_dedup: Bool) {
        self.has = has
        self.max_detour_meters = max_detour_meters
        self.max_detour_trucker_meters = max_detour_trucker_meters
        self.region_meters = region_meters
        self.shard_groups = shard_groups
        self.closed_fallback = closed_fallback
        self.empty_fallback = empty_fallback
        self.habit_pins = habit_pins
        self.nearest_leads = nearest_leads
        self.ratings_lookup = ratings_lookup
        self.brand_cost_tier = brand_cost_tier
        self.shower_ladder = shower_ladder
        self.location_dedup = location_dedup
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsPlacesKindPolicy {
        { let val = self; return __swift_bridge__$FlowsPlacesKindPolicy(has: val.has, max_detour_meters: val.max_detour_meters, max_detour_trucker_meters: val.max_detour_trucker_meters, region_meters: val.region_meters, shard_groups: val.shard_groups, closed_fallback: val.closed_fallback, empty_fallback: val.empty_fallback, habit_pins: val.habit_pins, nearest_leads: val.nearest_leads, ratings_lookup: val.ratings_lookup, brand_cost_tier: val.brand_cost_tier, shower_ladder: val.shower_ladder, location_dedup: val.location_dedup); }()
    }
}
extension __swift_bridge__$FlowsPlacesKindPolicy {
    @inline(__always)
    func intoSwiftRepr() -> FlowsPlacesKindPolicy {
        { let val = self; return FlowsPlacesKindPolicy(has: val.has, max_detour_meters: val.max_detour_meters, max_detour_trucker_meters: val.max_detour_trucker_meters, region_meters: val.region_meters, shard_groups: val.shard_groups, closed_fallback: val.closed_fallback, empty_fallback: val.empty_fallback, habit_pins: val.habit_pins, nearest_leads: val.nearest_leads, ratings_lookup: val.ratings_lookup, brand_cost_tier: val.brand_cost_tier, shower_ladder: val.shower_ladder, location_dedup: val.location_dedup); }()
    }
}
extension __swift_bridge__$Option$FlowsPlacesKindPolicy {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsPlacesKindPolicy> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsPlacesKindPolicy>) -> __swift_bridge__$Option$FlowsPlacesKindPolicy {
        if let v = val {
            return __swift_bridge__$Option$FlowsPlacesKindPolicy(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsPlacesKindPolicy(is_some: false, val: __swift_bridge__$FlowsPlacesKindPolicy())
        }
    }
}
public struct FlowsPlacesLimits {
    public var backtrack_tolerance_meters: Double
    public var max_detour_meters: Double
    public var detour_speed_mps: Double
    public var dollars_per_hour: Double
    public var average_nightly_price: Double
    public var ranked_rows: Int64
    public var instant_rows: Int64
    public var fallback_rows: Int64
    public var search_enough_hits: Int64
    public var named_enough_hits: Int64
    public var named_centers: Int64
    public var named_region_meters: Double

    public init(backtrack_tolerance_meters: Double,max_detour_meters: Double,detour_speed_mps: Double,dollars_per_hour: Double,average_nightly_price: Double,ranked_rows: Int64,instant_rows: Int64,fallback_rows: Int64,search_enough_hits: Int64,named_enough_hits: Int64,named_centers: Int64,named_region_meters: Double) {
        self.backtrack_tolerance_meters = backtrack_tolerance_meters
        self.max_detour_meters = max_detour_meters
        self.detour_speed_mps = detour_speed_mps
        self.dollars_per_hour = dollars_per_hour
        self.average_nightly_price = average_nightly_price
        self.ranked_rows = ranked_rows
        self.instant_rows = instant_rows
        self.fallback_rows = fallback_rows
        self.search_enough_hits = search_enough_hits
        self.named_enough_hits = named_enough_hits
        self.named_centers = named_centers
        self.named_region_meters = named_region_meters
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsPlacesLimits {
        { let val = self; return __swift_bridge__$FlowsPlacesLimits(backtrack_tolerance_meters: val.backtrack_tolerance_meters, max_detour_meters: val.max_detour_meters, detour_speed_mps: val.detour_speed_mps, dollars_per_hour: val.dollars_per_hour, average_nightly_price: val.average_nightly_price, ranked_rows: val.ranked_rows, instant_rows: val.instant_rows, fallback_rows: val.fallback_rows, search_enough_hits: val.search_enough_hits, named_enough_hits: val.named_enough_hits, named_centers: val.named_centers, named_region_meters: val.named_region_meters); }()
    }
}
extension __swift_bridge__$FlowsPlacesLimits {
    @inline(__always)
    func intoSwiftRepr() -> FlowsPlacesLimits {
        { let val = self; return FlowsPlacesLimits(backtrack_tolerance_meters: val.backtrack_tolerance_meters, max_detour_meters: val.max_detour_meters, detour_speed_mps: val.detour_speed_mps, dollars_per_hour: val.dollars_per_hour, average_nightly_price: val.average_nightly_price, ranked_rows: val.ranked_rows, instant_rows: val.instant_rows, fallback_rows: val.fallback_rows, search_enough_hits: val.search_enough_hits, named_enough_hits: val.named_enough_hits, named_centers: val.named_centers, named_region_meters: val.named_region_meters); }()
    }
}
extension __swift_bridge__$Option$FlowsPlacesLimits {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsPlacesLimits> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsPlacesLimits>) -> __swift_bridge__$Option$FlowsPlacesLimits {
        if let v = val {
            return __swift_bridge__$Option$FlowsPlacesLimits(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsPlacesLimits(is_some: false, val: __swift_bridge__$FlowsPlacesLimits())
        }
    }
}

public class FlowsPlacesIndex: FlowsPlacesIndexRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FlowsPlacesIndex$_free(ptr)
        }
    }
}
public class FlowsPlacesIndexRefMut: FlowsPlacesIndexRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FlowsPlacesIndexRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FlowsPlacesIndexRef {
    public func count() -> Int64 {
        __swift_bridge__$FlowsPlacesIndex$count(ptr)
    }

    public func places_near(_ data: UnsafeBufferPointer<UInt8>, _ lat: Double, _ lon: Double, _ groups: UnsafeBufferPointer<UInt8>, _ radius_meters: Double, _ limit: Int64) -> RustVec<Int64> {
        RustVec(ptr: __swift_bridge__$FlowsPlacesIndex$places_near(ptr, data.toFfiSlice(), lat, lon, groups.toFfiSlice(), radius_meters, limit))
    }

    public func place_numbers(_ data: UnsafeBufferPointer<UInt8>, _ index: Int64) -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsPlacesIndex$place_numbers(ptr, data.toFfiSlice(), index))
    }

    public func place_texts(_ data: UnsafeBufferPointer<UInt8>, _ index: Int64) -> RustVec<RustString> {
        RustVec(ptr: __swift_bridge__$FlowsPlacesIndex$place_texts(ptr, data.toFfiSlice(), index))
    }
}
extension FlowsPlacesIndex: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FlowsPlacesIndex$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FlowsPlacesIndex$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FlowsPlacesIndex) {
        __swift_bridge__$Vec_FlowsPlacesIndex$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FlowsPlacesIndex$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FlowsPlacesIndex(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsPlacesIndexRef> {
        let pointer = __swift_bridge__$Vec_FlowsPlacesIndex$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsPlacesIndexRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsPlacesIndexRefMut> {
        let pointer = __swift_bridge__$Vec_FlowsPlacesIndex$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsPlacesIndexRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FlowsPlacesIndexRef> {
        UnsafePointer<FlowsPlacesIndexRef>(OpaquePointer(__swift_bridge__$Vec_FlowsPlacesIndex$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FlowsPlacesIndex$len(vecPtr)
    }
}


public class FlowsRoutePath: FlowsRoutePathRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FlowsRoutePath$_free(ptr)
        }
    }
}
public class FlowsRoutePathRefMut: FlowsRoutePathRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
public class FlowsRoutePathRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FlowsRoutePathRef {
    public func cumulative() -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsRoutePath$cumulative(ptr))
    }

    public func nearest(_ lat: Double, _ lon: Double) -> FlowsPlacesNearest {
        __swift_bridge__$FlowsRoutePath$nearest(ptr, lat, lon).intoSwiftRepr()
    }

    public func annotate(_ lat: Double, _ lon: Double, _ vehicle_along: Double) -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsRoutePath$annotate(ptr, lat, lon, vehicle_along))
    }

    public func rank_along<GenericToRustStr: ToRustStr>(_ kind: UInt8, _ has_fuel: Bool, _ fuel: UInt8, _ trucker: Bool, _ has_position: Bool, _ lat: Double, _ lon: Double, _ item_lats: UnsafeBufferPointer<Double>, _ item_lons: UnsafeBufferPointer<Double>, _ prices: UnsafeBufferPointer<Double>, _ has_price: UnsafeBufferPointer<UInt8>, _ ratings: UnsafeBufferPointer<Double>, _ has_rating: UnsafeBufferPointer<UInt8>, _ names_joined: GenericToRustStr, _ name_lens: UnsafeBufferPointer<Int64>, _ name_present: UnsafeBufferPointer<UInt8>) -> RustVec<Double> {
        return names_joined.toRustStr({ names_joinedAsRustStr in
            RustVec(ptr: __swift_bridge__$FlowsRoutePath$rank_along(ptr, kind, has_fuel, fuel, trucker, has_position, lat, lon, item_lats.toFfiSlice(), item_lons.toFfiSlice(), prices.toFfiSlice(), has_price.toFfiSlice(), ratings.toFfiSlice(), has_rating.toFfiSlice(), names_joinedAsRustStr, name_lens.toFfiSlice(), name_present.toFfiSlice()))
        })
    }
}
extension FlowsRoutePath: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FlowsRoutePath$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FlowsRoutePath$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FlowsRoutePath) {
        __swift_bridge__$Vec_FlowsRoutePath$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FlowsRoutePath$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FlowsRoutePath(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsRoutePathRef> {
        let pointer = __swift_bridge__$Vec_FlowsRoutePath$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsRoutePathRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsRoutePathRefMut> {
        let pointer = __swift_bridge__$Vec_FlowsRoutePath$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsRoutePathRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FlowsRoutePathRef> {
        UnsafePointer<FlowsRoutePathRef>(OpaquePointer(__swift_bridge__$Vec_FlowsRoutePath$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FlowsRoutePath$len(vecPtr)
    }
}



public func flows_places_text_cost_tier<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> Int64 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_cost_tier(nameAsRustStr)
    })
}
public func flows_places_text_website<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_places_text_website(nameAsRustStr))
    })
}
public func flows_places_text_gym_has_showers<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> Int32 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_gym_has_showers(nameAsRustStr)
    })
}
public func flows_places_text_parking_fee<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> Int32 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_parking_fee(nameAsRustStr)
    })
}
public func flows_places_text_shelter_type<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ query: GenericToRustStr) -> UInt8 {
    return query.toRustStr({ queryAsRustStr in
        return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_shelter_type(nameAsRustStr, queryAsRustStr)
    })
    })
}
public func flows_places_text_is_shelter_noise<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> Bool {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_is_shelter_noise(nameAsRustStr)
    })
}
public func flows_places_text_asked_name_matches<GenericToRustStr: ToRustStr>(_ asked: GenericToRustStr, _ name: GenericToRustStr) -> Bool {
    return name.toRustStr({ nameAsRustStr in
        return asked.toRustStr({ askedAsRustStr in
        __swift_bridge__$flows_places_text_asked_name_matches(askedAsRustStr, nameAsRustStr)
    })
    })
}
public func flows_places_text_country_for_coordinate(_ latitude: Double, _ longitude: Double) -> UInt8 {
    __swift_bridge__$flows_places_text_country_for_coordinate(latitude, longitude)
}
public func flows_places_text_check_breakpoints(_ country: UInt8) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_places_text_check_breakpoints(country))
}
public func flows_places_text_cost_tier_for_check(_ average_check: Double, _ country: UInt8) -> Int64 {
    __swift_bridge__$flows_places_text_cost_tier_for_check(average_check, country)
}
public func flows_places_text_estimated_nightly(_ cost_tier: Int64, _ has_tier: Bool) -> Double {
    __swift_bridge__$flows_places_text_estimated_nightly(cost_tier, has_tier)
}
public func flows_places_text_yelp_cost_tier<GenericToRustStr: ToRustStr>(_ price: GenericToRustStr, _ rating: Double, _ has_rating: Bool) -> Int64 {
    return price.toRustStr({ priceAsRustStr in
        __swift_bridge__$flows_places_text_yelp_cost_tier(priceAsRustStr, rating, has_rating)
    })
}
public func flows_places_text_shower_for_name<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool) -> UInt8 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_shower_for_name(nameAsRustStr, has_name)
    })
}
public func flows_places_text_shower_ladder<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool, _ has_position: Bool, _ disproved: Bool, _ tag: GenericToRustStr, _ has_tag: Bool) -> UInt8 {
    return tag.toRustStr({ tagAsRustStr in
        return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_places_text_shower_ladder(nameAsRustStr, has_name, has_position, disproved, tagAsRustStr, has_tag)
    })
    })
}
public func flows_places_text_shower_table_entry(_ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ latitude: Double, _ longitude: Double) -> Int64 {
    __swift_bridge__$flows_places_text_shower_table_entry(lats.toFfiSlice(), lons.toFfiSlice(), latitude, longitude)
}
public func flows_places_text_city_keys<GenericToRustStr: ToRustStr>(_ state: GenericToRustStr, _ city: GenericToRustStr) -> RustVec<RustString> {
    return city.toRustStr({ cityAsRustStr in
        return state.toRustStr({ stateAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_places_text_city_keys(stateAsRustStr, cityAsRustStr))
    })
    })
}
public func flows_places_text_lowercased<GenericToRustStr: ToRustStr>(_ text: GenericToRustStr) -> RustString {
    return text.toRustStr({ textAsRustStr in
        RustString(ptr: __swift_bridge__$flows_places_text_lowercased(textAsRustStr))
    })
}
public func flows_places_text_uppercased<GenericToRustStr: ToRustStr>(_ text: GenericToRustStr) -> RustString {
    return text.toRustStr({ textAsRustStr in
        RustString(ptr: __swift_bridge__$flows_places_text_uppercased(textAsRustStr))
    })
}
public func flows_places_text_national_gas() -> Double {
    __swift_bridge__$flows_places_text_national_gas()
}
public func flows_places_text_national_diesel() -> Double {
    __swift_bridge__$flows_places_text_national_diesel()
}
public func flows_places_text_national_kwh() -> Double {
    __swift_bridge__$flows_places_text_national_kwh()
}
public func flows_places_text_mxn_per_usd() -> Double {
    __swift_bridge__$flows_places_text_mxn_per_usd()
}
public func flows_places_text_liters_per_gallon() -> Double {
    __swift_bridge__$flows_places_text_liters_per_gallon()
}
public func flows_places_text_usd_per_gallon(_ mxn_per_liter: Double) -> Double {
    __swift_bridge__$flows_places_text_usd_per_gallon(mxn_per_liter)
}
public func flows_places_text_mexico_estimate(_ fuel: UInt8) -> Double {
    __swift_bridge__$flows_places_text_mexico_estimate(fuel)
}
public func flows_places_text_fuel_state_code<GenericToRustStr: ToRustStr>(_ state: GenericToRustStr, _ has_state: Bool) -> RustString {
    return state.toRustStr({ stateAsRustStr in
        RustString(ptr: __swift_bridge__$flows_places_text_fuel_state_code(stateAsRustStr, has_state))
    })
}
public func flows_places_text_fuel_estimate<GenericToRustStr: ToRustStr>(_ fuel: UInt8, _ code: GenericToRustStr, _ has_code: Bool, _ live_gas: Double, _ live_diesel: Double, _ has_live: Bool) -> Double {
    return code.toRustStr({ codeAsRustStr in
        __swift_bridge__$flows_places_text_fuel_estimate(fuel, codeAsRustStr, has_code, live_gas, live_diesel, has_live)
    })
}
public func flows_places_text_parse_current_avg<GenericToRustStr: ToRustStr>(_ html: GenericToRustStr) -> FlowsPlacesTextPrices {
    return html.toRustStr({ htmlAsRustStr in
        __swift_bridge__$flows_places_text_parse_current_avg(htmlAsRustStr).intoSwiftRepr()
    })
}
public func flows_places_text_state_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_places_text_state_names())
}
public func flows_places_text_state_codes() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_places_text_state_codes())
}
public func flows_places_text_parse_turn_lanes<GenericToRustStr: ToRustStr>(_ turn_lanes: GenericToRustStr) -> RustVec<Int64> {
    return turn_lanes.toRustStr({ turn_lanesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_places_text_parse_turn_lanes(turn_lanesAsRustStr))
    })
}
public func flows_places_text_turn_side(_ turn: UInt8) -> UInt8 {
    __swift_bridge__$flows_places_text_turn_side(turn)
}
public func flows_places_text_lane_allows(_ turns: UnsafeBufferPointer<Int64>, _ side: UInt8) -> Bool {
    __swift_bridge__$flows_places_text_lane_allows(turns.toFfiSlice(), side)
}
public func flows_places_text_recommended_lanes(_ lanes_flat: UnsafeBufferPointer<Int64>, _ side: UInt8) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_places_text_recommended_lanes(lanes_flat.toFfiSlice(), side))
}
public func flows_places_text_camera_kind<GenericToRustStr: ToRustStr>(_ highway: GenericToRustStr, _ enforcement: GenericToRustStr, _ traffic_signals: GenericToRustStr, _ red_light_camera: GenericToRustStr) -> Int32 {
    return red_light_camera.toRustStr({ red_light_cameraAsRustStr in
        return traffic_signals.toRustStr({ traffic_signalsAsRustStr in
        return enforcement.toRustStr({ enforcementAsRustStr in
        return highway.toRustStr({ highwayAsRustStr in
        __swift_bridge__$flows_places_text_camera_kind(highwayAsRustStr, enforcementAsRustStr, traffic_signalsAsRustStr, red_light_cameraAsRustStr)
    })
    })
    })
    })
}
public func flows_places_text_camera_limit_mph<GenericToRustStr: ToRustStr>(_ maxspeed: GenericToRustStr, _ has_maxspeed: Bool) -> FlowsPlacesTextOptional {
    return maxspeed.toRustStr({ maxspeedAsRustStr in
        __swift_bridge__$flows_places_text_camera_limit_mph(maxspeedAsRustStr, has_maxspeed).intoSwiftRepr()
    })
}
public struct FlowsPlacesTextOptional {
    public var is_some: Double
    public var value: Double

    public init(is_some: Double,value: Double) {
        self.is_some = is_some
        self.value = value
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsPlacesTextOptional {
        { let val = self; return __swift_bridge__$FlowsPlacesTextOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$FlowsPlacesTextOptional {
    @inline(__always)
    func intoSwiftRepr() -> FlowsPlacesTextOptional {
        { let val = self; return FlowsPlacesTextOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$Option$FlowsPlacesTextOptional {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsPlacesTextOptional> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsPlacesTextOptional>) -> __swift_bridge__$Option$FlowsPlacesTextOptional {
        if let v = val {
            return __swift_bridge__$Option$FlowsPlacesTextOptional(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsPlacesTextOptional(is_some: false, val: __swift_bridge__$FlowsPlacesTextOptional())
        }
    }
}
public struct FlowsPlacesTextPrices {
    public var has: Double
    public var gas: Double
    public var diesel: Double

    public init(has: Double,gas: Double,diesel: Double) {
        self.has = has
        self.gas = gas
        self.diesel = diesel
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsPlacesTextPrices {
        { let val = self; return __swift_bridge__$FlowsPlacesTextPrices(has: val.has, gas: val.gas, diesel: val.diesel); }()
    }
}
extension __swift_bridge__$FlowsPlacesTextPrices {
    @inline(__always)
    func intoSwiftRepr() -> FlowsPlacesTextPrices {
        { let val = self; return FlowsPlacesTextPrices(has: val.has, gas: val.gas, diesel: val.diesel); }()
    }
}
extension __swift_bridge__$Option$FlowsPlacesTextPrices {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsPlacesTextPrices> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsPlacesTextPrices>) -> __swift_bridge__$Option$FlowsPlacesTextPrices {
        if let v = val {
            return __swift_bridge__$Option$FlowsPlacesTextPrices(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsPlacesTextPrices(is_some: false, val: __swift_bridge__$FlowsPlacesTextPrices())
        }
    }
}


public func flows_rides_parse_coordinate<GenericToRustStr: ToRustStr>(_ text: GenericToRustStr) -> FlowsRidesPoint {
    return text.toRustStr({ textAsRustStr in
        __swift_bridge__$flows_rides_parse_coordinate(textAsRustStr).intoSwiftRepr()
    })
}
public func flows_rides_recents_cap() -> Int64 {
    __swift_bridge__$flows_rides_recents_cap()
}
public func flows_rides_recent_score(_ uses: Int64, _ last_used: Double, _ now: Double) -> Double {
    __swift_bridge__$flows_rides_recent_score(uses, last_used, now)
}
public func flows_rides_recordable_name<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_rides_recordable_name(nameAsRustStr))
    })
}
public func flows_rides_merged_recents<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ name_lengths: UnsafeBufferPointer<Int64>, _ last_used: UnsafeBufferPointer<Double>, _ uses: UnsafeBufferPointer<Int64>, _ count: Int64, _ new_name: GenericToRustStr, _ new_last_used: Double, _ new_uses: Int64, _ now: Double) -> RustVec<Int64> {
    return new_name.toRustStr({ new_nameAsRustStr in
        return names.toRustStr({ namesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_rides_merged_recents(namesAsRustStr, name_lengths.toFfiSlice(), last_used.toFfiSlice(), uses.toFfiSlice(), count, new_nameAsRustStr, new_last_used, new_uses, now))
    })
    })
}
public func flows_rides_matching_recents<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ name_lengths: UnsafeBufferPointer<Int64>, _ count: Int64, _ fragment: GenericToRustStr, _ limit: Int64) -> RustVec<Int64> {
    return fragment.toRustStr({ fragmentAsRustStr in
        return names.toRustStr({ namesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_rides_matching_recents(namesAsRustStr, name_lengths.toFfiSlice(), count, fragmentAsRustStr, limit))
    })
    })
}
public func flows_rides_blend_suggestions<GenericToRustStr: ToRustStr>(_ pinned: GenericToRustStr, _ pinned_lengths: UnsafeBufferPointer<Int64>, _ pinned_count: Int64, _ completions: GenericToRustStr, _ completion_lengths: UnsafeBufferPointer<Int64>, _ completion_count: Int64, _ cap: Int64) -> RustVec<Int64> {
    return completions.toRustStr({ completionsAsRustStr in
        return pinned.toRustStr({ pinnedAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_rides_blend_suggestions(pinnedAsRustStr, pinned_lengths.toFfiSlice(), pinned_count, completionsAsRustStr, completion_lengths.toFfiSlice(), completion_count, cap))
    })
    })
}
public func flows_rides_ride_multiplier<GenericToRustStr: ToRustStr>(_ mode: GenericToRustStr) -> Double {
    return mode.toRustStr({ modeAsRustStr in
        __swift_bridge__$flows_rides_ride_multiplier(modeAsRustStr)
    })
}
public func flows_rides_fallback_mph<GenericToRustStr: ToRustStr>(_ mode: GenericToRustStr) -> Double {
    return mode.toRustStr({ modeAsRustStr in
        __swift_bridge__$flows_rides_fallback_mph(modeAsRustStr)
    })
}
public func flows_rides_ride_duration<GenericToRustStr: ToRustStr>(_ mode: GenericToRustStr, _ drive_seconds: Double, _ has_drive: Bool, _ miles: Double) -> Double {
    return mode.toRustStr({ modeAsRustStr in
        __swift_bridge__$flows_rides_ride_duration(modeAsRustStr, drive_seconds, has_drive, miles)
    })
}
public func flows_rides_rental_brands() -> RustString {
    RustString(ptr: __swift_bridge__$flows_rides_rental_brands())
}
public func flows_rides_rental_brand_lengths() -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_rides_rental_brand_lengths())
}
public func flows_rides_rental_brand_rank<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool) -> Int64 {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_rides_rental_brand_rank(nameAsRustStr, has_name)
    })
}
public func flows_rides_rental_booking_site<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_rides_rental_booking_site(nameAsRustStr, has_name))
    })
}
public func flows_rides_recommend_rentals<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ name_lengths: UnsafeBufferPointer<Int64>, _ miles: UnsafeBufferPointer<Double>, _ count: Int64, _ limit: Int64) -> RustVec<Int64> {
    return names.toRustStr({ namesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_rides_recommend_rentals(namesAsRustStr, name_lengths.toFfiSlice(), miles.toFfiSlice(), count, limit))
    })
}
public func flows_rides_radio_purpose<GenericToRustStr: ToRustStr>(_ channel: GenericToRustStr) -> UInt8 {
    return channel.toRustStr({ channelAsRustStr in
        __swift_bridge__$flows_rides_radio_purpose(channelAsRustStr)
    })
}
public func flows_rides_radio_is_car_band<GenericToRustStr: ToRustStr>(_ channel: GenericToRustStr) -> Bool {
    return channel.toRustStr({ channelAsRustStr in
        __swift_bridge__$flows_rides_radio_is_car_band(channelAsRustStr)
    })
}
public func flows_rides_radio_advance(_ index: Int64, _ count: Int64, _ step: Int64) -> Int64 {
    __swift_bridge__$flows_rides_radio_advance(index, count, step)
}
public func flows_rides_radio_state_code<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_rides_radio_state_code(nameAsRustStr))
    })
}
public func flows_rides_radio_position<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ lat: Double, _ has_lat: Bool, _ lon: Double, _ has_lon: Bool) -> FlowsRidesPosition {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_rides_radio_position(nameAsRustStr, lat, has_lat, lon, has_lon).intoSwiftRepr()
    })
}
public struct FlowsRidesPoint {
    public var has: Bool
    public var lat: Double
    public var lon: Double

    public init(has: Bool,lat: Double,lon: Double) {
        self.has = has
        self.lat = lat
        self.lon = lon
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsRidesPoint {
        { let val = self; return __swift_bridge__$FlowsRidesPoint(has: val.has, lat: val.lat, lon: val.lon); }()
    }
}
extension __swift_bridge__$FlowsRidesPoint {
    @inline(__always)
    func intoSwiftRepr() -> FlowsRidesPoint {
        { let val = self; return FlowsRidesPoint(has: val.has, lat: val.lat, lon: val.lon); }()
    }
}
extension __swift_bridge__$Option$FlowsRidesPoint {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsRidesPoint> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsRidesPoint>) -> __swift_bridge__$Option$FlowsRidesPoint {
        if let v = val {
            return __swift_bridge__$Option$FlowsRidesPoint(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsRidesPoint(is_some: false, val: __swift_bridge__$FlowsRidesPoint())
        }
    }
}
public struct FlowsRidesPosition {
    public var has: Bool
    public var lat: Double
    public var lon: Double
    public var exact: Bool

    public init(has: Bool,lat: Double,lon: Double,exact: Bool) {
        self.has = has
        self.lat = lat
        self.lon = lon
        self.exact = exact
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsRidesPosition {
        { let val = self; return __swift_bridge__$FlowsRidesPosition(has: val.has, lat: val.lat, lon: val.lon, exact: val.exact); }()
    }
}
extension __swift_bridge__$FlowsRidesPosition {
    @inline(__always)
    func intoSwiftRepr() -> FlowsRidesPosition {
        { let val = self; return FlowsRidesPosition(has: val.has, lat: val.lat, lon: val.lon, exact: val.exact); }()
    }
}
extension __swift_bridge__$Option$FlowsRidesPosition {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsRidesPosition> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsRidesPosition>) -> __swift_bridge__$Option$FlowsRidesPosition {
        if let v = val {
            return __swift_bridge__$Option$FlowsRidesPosition(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsRidesPosition(is_some: false, val: __swift_bridge__$FlowsRidesPosition())
        }
    }
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


public func flows_risk_field_parse_frb1(_ data: UnsafeBufferPointer<UInt8>) -> Optional<FlowsRiskField> {
    { let val = __swift_bridge__$flows_risk_field_parse_frb1(data.toFfiSlice()); if val != nil { return FlowsRiskField(ptr: val!) } else { return nil } }()
}
public func flows_risk_field_empty<GenericToRustStr: ToRustStr>(_ generated: GenericToRustStr, _ families_joined: GenericToRustStr, _ family_lens: UnsafeBufferPointer<Int64>, _ family_count: Int64) -> FlowsRiskField {
    return families_joined.toRustStr({ families_joinedAsRustStr in
        return generated.toRustStr({ generatedAsRustStr in
        FlowsRiskField(ptr: __swift_bridge__$flows_risk_field_empty(generatedAsRustStr, families_joinedAsRustStr, family_lens.toFfiSlice(), family_count))
    })
    })
}
public func flows_risk_field_from_columns<GenericToRustStr: ToRustStr>(_ generated: GenericToRustStr, _ families_joined: GenericToRustStr, _ family_lens: UnsafeBufferPointer<Int64>, _ family_count: Int64, _ zips_joined: GenericToRustStr, _ zip_lens: UnsafeBufferPointer<Int64>, _ lats: UnsafeBufferPointer<Double>, _ lons: UnsafeBufferPointer<Double>, _ score_counts: UnsafeBufferPointer<Int64>, _ scores: UnsafeBufferPointer<Double>, _ summaries_joined: GenericToRustStr, _ summary_lens: UnsafeBufferPointer<Int64>, _ has_summary: UnsafeBufferPointer<Int64>, _ ring_counts: UnsafeBufferPointer<Int64>, _ has_ring: UnsafeBufferPointer<Int64>, _ ring_points: UnsafeBufferPointer<Double>) -> Optional<FlowsRiskField> {
    return summaries_joined.toRustStr({ summaries_joinedAsRustStr in
        return zips_joined.toRustStr({ zips_joinedAsRustStr in
        return families_joined.toRustStr({ families_joinedAsRustStr in
        return generated.toRustStr({ generatedAsRustStr in
        { let val = __swift_bridge__$flows_risk_field_from_columns(generatedAsRustStr, families_joinedAsRustStr, family_lens.toFfiSlice(), family_count, zips_joinedAsRustStr, zip_lens.toFfiSlice(), lats.toFfiSlice(), lons.toFfiSlice(), score_counts.toFfiSlice(), scores.toFfiSlice(), summaries_joinedAsRustStr, summary_lens.toFfiSlice(), has_summary.toFfiSlice(), ring_counts.toFfiSlice(), has_ring.toFfiSlice(), ring_points.toFfiSlice()); if val != nil { return FlowsRiskField(ptr: val!) } else { return nil } }()
    })
    })
    })
    })
}



public class FlowsRiskField: FlowsRiskFieldRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$FlowsRiskField$_free(ptr)
        }
    }
}
public class FlowsRiskFieldRefMut: FlowsRiskFieldRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
extension FlowsRiskFieldRefMut {
    public func harmonic_rescore(_ table: FlowsHarmonicTableRef, _ week: Int64) -> Int64 {
        __swift_bridge__$FlowsRiskField$harmonic_rescore(ptr, table.ptr, week)
    }
}
public class FlowsRiskFieldRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension FlowsRiskFieldRef {
    public func generated() -> RustString {
        RustString(ptr: __swift_bridge__$FlowsRiskField$generated(ptr))
    }

    public func families() -> RustVec<RustString> {
        RustVec(ptr: __swift_bridge__$FlowsRiskField$families(ptr))
    }

    public func family_index<GenericToRustStr: ToRustStr>(_ family: GenericToRustStr) -> Int64 {
        return family.toRustStr({ familyAsRustStr in
            __swift_bridge__$FlowsRiskField$family_index(ptr, familyAsRustStr)
        })
    }

    public func count() -> Int64 {
        __swift_bridge__$FlowsRiskField$count(ptr)
    }

    public func zip(_ index: Int64) -> RustString {
        RustString(ptr: __swift_bridge__$FlowsRiskField$zip(ptr, index))
    }

    public func latitude(_ index: Int64) -> Double {
        __swift_bridge__$FlowsRiskField$latitude(ptr, index)
    }

    public func longitude(_ index: Int64) -> Double {
        __swift_bridge__$FlowsRiskField$longitude(ptr, index)
    }

    public func scores(_ index: Int64) -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsRiskField$scores(ptr, index))
    }

    public func has_summary(_ index: Int64) -> Bool {
        __swift_bridge__$FlowsRiskField$has_summary(ptr, index)
    }

    public func summary(_ index: Int64) -> RustString {
        RustString(ptr: __swift_bridge__$FlowsRiskField$summary(ptr, index))
    }

    public func has_ring(_ index: Int64) -> Bool {
        __swift_bridge__$FlowsRiskField$has_ring(ptr, index)
    }

    public func ring(_ index: Int64) -> RustVec<Double> {
        RustVec(ptr: __swift_bridge__$FlowsRiskField$ring(ptr, index))
    }

    public func nearest(_ latitude: Double, _ longitude: Double) -> Int64 {
        __swift_bridge__$FlowsRiskField$nearest(ptr, latitude, longitude)
    }

    public func select(_ lat_min: Double, _ lat_max: Double, _ lon_min: Double, _ lon_max: Double, _ family_index: Int64, _ limit: Int64) -> RustVec<Int64> {
        RustVec(ptr: __swift_bridge__$FlowsRiskField$select(ptr, lat_min, lat_max, lon_min, lon_max, family_index, limit))
    }
}
extension FlowsRiskField: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_FlowsRiskField$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_FlowsRiskField$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: FlowsRiskField) {
        __swift_bridge__$Vec_FlowsRiskField$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_FlowsRiskField$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (FlowsRiskField(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsRiskFieldRef> {
        let pointer = __swift_bridge__$Vec_FlowsRiskField$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsRiskFieldRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<FlowsRiskFieldRefMut> {
        let pointer = __swift_bridge__$Vec_FlowsRiskField$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return FlowsRiskFieldRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<FlowsRiskFieldRef> {
        UnsafePointer<FlowsRiskFieldRef>(OpaquePointer(__swift_bridge__$Vec_FlowsRiskField$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_FlowsRiskField$len(vecPtr)
    }
}



public func flows_seasonal_cross_country_km() -> Double {
    __swift_bridge__$flows_seasonal_cross_country_km()
}
public func flows_seasonal_local_trip_threshold() -> Int64 {
    __swift_bridge__$flows_seasonal_local_trip_threshold()
}
public func flows_seasonal_cross_country_trip_threshold() -> Int64 {
    __swift_bridge__$flows_seasonal_cross_country_trip_threshold()
}
public func flows_seasonal_min_week_samples_for_confidence() -> Double {
    __swift_bridge__$flows_seasonal_min_week_samples_for_confidence()
}
public func flows_seasonal_decay_half_life_weeks() -> Double {
    __swift_bridge__$flows_seasonal_decay_half_life_weeks()
}
public func flows_seasonal_home_min_trips() -> Int64 {
    __swift_bridge__$flows_seasonal_home_min_trips()
}
public func flows_seasonal_max_edges() -> Int64 {
    __swift_bridge__$flows_seasonal_max_edges()
}
public func flows_seasonal_max_origins() -> Int64 {
    __swift_bridge__$flows_seasonal_max_origins()
}
public func flows_seasonal_origin_half_life_days() -> Double {
    __swift_bridge__$flows_seasonal_origin_half_life_days()
}
public func flows_seasonal_relocation_margin() -> Double {
    __swift_bridge__$flows_seasonal_relocation_margin()
}
public func flows_seasonal_relocation_min_days() -> Double {
    __swift_bridge__$flows_seasonal_relocation_min_days()
}
public func flows_seasonal_route_feature_count() -> Int64 {
    __swift_bridge__$flows_seasonal_route_feature_count()
}
public func flows_seasonal_tune_epochs() -> Int64 {
    __swift_bridge__$flows_seasonal_tune_epochs()
}
public func flows_seasonal_tune_learning_rate() -> Double {
    __swift_bridge__$flows_seasonal_tune_learning_rate()
}
public func flows_seasonal_tune_anchor() -> Double {
    __swift_bridge__$flows_seasonal_tune_anchor()
}
public func flows_seasonal_tune_min_trips() -> Int64 {
    __swift_bridge__$flows_seasonal_tune_min_trips()
}
public func flows_seasonal_tune_min_interval_seconds() -> Double {
    __swift_bridge__$flows_seasonal_tune_min_interval_seconds()
}
public func flows_seasonal_tune_min_new_trips() -> Int64 {
    __swift_bridge__$flows_seasonal_tune_min_new_trips()
}
public func flows_seasonal_week_stat_decayed(_ stat: FlowsSeasonalWeekStat, _ t: Double, _ half_life_weeks: Double) -> FlowsSeasonalWeekStat {
    __swift_bridge__$flows_seasonal_week_stat_decayed(stat.intoFfiRepr(), t, half_life_weeks).intoSwiftRepr()
}
public func flows_seasonal_week_stat_added(_ stat: FlowsSeasonalWeekStat, _ observed: Double, _ predicted: Double, _ t: Double, _ half_life_weeks: Double) -> FlowsSeasonalWeekStat {
    __swift_bridge__$flows_seasonal_week_stat_added(stat.intoFfiRepr(), observed, predicted, t, half_life_weeks).intoSwiftRepr()
}
public func flows_seasonal_mean_observed(_ w_sum: Double, _ w_observed: Double) -> Double {
    __swift_bridge__$flows_seasonal_mean_observed(w_sum, w_observed)
}
public func flows_seasonal_is_modeled(_ trip_count: Int64, _ cross_country: Bool) -> Bool {
    __swift_bridge__$flows_seasonal_is_modeled(trip_count, cross_country)
}
public func flows_seasonal_is_cross_country(_ distance_km: Double) -> Bool {
    __swift_bridge__$flows_seasonal_is_cross_country(distance_km)
}
public func flows_seasonal_next_count(_ count: Int64) -> Int64 {
    __swift_bridge__$flows_seasonal_next_count(count)
}
public func flows_seasonal_prior_week_keys(_ week: Int64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_prior_week_keys(week))
}
public func flows_seasonal_prior(_ trip_count: Int64, _ cross_country: Bool, _ week: Int64, _ cells: UnsafeBufferPointer<Double>, _ present: UnsafeBufferPointer<Double>, _ now: Double) -> FlowsSeasonalPrior {
    __swift_bridge__$flows_seasonal_prior(trip_count, cross_country, week, cells.toFfiSlice(), present.toFfiSlice(), now).intoSwiftRepr()
}
public func flows_seasonal_accuracy(_ trip_count: Int64, _ stats: UnsafeBufferPointer<Double>, _ now: Double) -> FlowsSeasonalOptional {
    __swift_bridge__$flows_seasonal_accuracy(trip_count, stats.toFfiSlice(), now).intoSwiftRepr()
}
public func flows_seasonal_mean_in_order(_ values: UnsafeBufferPointer<Double>) -> FlowsSeasonalOptional {
    __swift_bridge__$flows_seasonal_mean_in_order(values.toFfiSlice()).intoSwiftRepr()
}
public func flows_seasonal_training_rows(_ cells: UnsafeBufferPointer<Double>, _ now: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_training_rows(cells.toFfiSlice(), now))
}
public func flows_seasonal_route_cell(_ degrees: Double) -> FlowsSeasonalOptional {
    __swift_bridge__$flows_seasonal_route_cell(degrees).intoSwiftRepr()
}
public func flows_seasonal_route_cell_degrees(_ cell: Int64) -> Double {
    __swift_bridge__$flows_seasonal_route_cell_degrees(cell)
}
public func flows_seasonal_path_edge_keys(_ hubs: UnsafeBufferPointer<Double>) -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_path_edge_keys(hubs.toFfiSlice()))
}
public func flows_seasonal_origin_key(_ lat: Int64, _ lon: Int64) -> RustString {
    RustString(ptr: __swift_bridge__$flows_seasonal_origin_key(lat, lon))
}
public func flows_seasonal_parse_origin_key<GenericToRustStr: ToRustStr>(_ key: GenericToRustStr) -> FlowsSeasonalCell {
    return key.toRustStr({ keyAsRustStr in
        __swift_bridge__$flows_seasonal_parse_origin_key(keyAsRustStr).intoSwiftRepr()
    })
}
public func flows_seasonal_origin_decayed(_ weighted: Double, _ last_seen: Double, _ now: Double) -> Double {
    __swift_bridge__$flows_seasonal_origin_decayed(weighted, last_seen, now)
}
public func flows_seasonal_origin_after_trip(_ prior: FlowsSeasonalOriginStat, _ t: Double) -> FlowsSeasonalOriginStat {
    __swift_bridge__$flows_seasonal_origin_after_trip(prior.intoFfiRepr(), t).intoSwiftRepr()
}
public func flows_seasonal_origins_over_cap(_ count: Int64) -> Bool {
    __swift_bridge__$flows_seasonal_origins_over_cap(count)
}
public func flows_seasonal_origin_evictions(_ stats: UnsafeBufferPointer<Double>, _ now: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_origin_evictions(stats.toFfiSlice(), now))
}
public func flows_seasonal_edge_freshness(_ last_ts: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_seasonal_edge_freshness(last_ts.toFfiSlice())
}
public func flows_seasonal_edges_over_cap(_ count: Int64) -> Bool {
    __swift_bridge__$flows_seasonal_edges_over_cap(count)
}
public func flows_seasonal_edge_evictions(_ freshness: UnsafeBufferPointer<Double>) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_edge_evictions(freshness.toFfiSlice()))
}
public func flows_seasonal_learned_home(_ entries: UnsafeBufferPointer<Double>, _ now: Double, _ current_lat: Int64, _ current_lon: Int64, _ has_current: Bool) -> FlowsSeasonalHome {
    __swift_bridge__$flows_seasonal_learned_home(entries.toFfiSlice(), now, current_lat, current_lon, has_current).intoSwiftRepr()
}
public func flows_seasonal_legacy_home(_ routes: UnsafeBufferPointer<Double>) -> FlowsSeasonalHome {
    __swift_bridge__$flows_seasonal_legacy_home(routes.toFfiSlice()).intoSwiftRepr()
}
public func flows_seasonal_route_features(_ o_lat: Double, _ o_lon: Double, _ d_lat: Double, _ d_lon: Double, _ week: Int64, _ cross_country: Bool) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_route_features(o_lat, o_lon, d_lat, d_lon, week, cross_country))
}
public func flows_seasonal_head_predict(_ buffer: UnsafeBufferPointer<Double>) -> Double {
    __swift_bridge__$flows_seasonal_head_predict(buffer.toFfiSlice())
}
public func flows_seasonal_fine_tune(_ head: UnsafeBufferPointer<Double>, _ rows: UnsafeBufferPointer<Double>, _ epochs: Int64, _ learning_rate: Double, _ anchor: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_seasonal_fine_tune(head.toFfiSlice(), rows.toFfiSlice(), epochs, learning_rate, anchor))
}
public func flows_seasonal_mean_squared_error(_ head: UnsafeBufferPointer<Double>, _ rows: UnsafeBufferPointer<Double>) -> FlowsSeasonalOptional {
    __swift_bridge__$flows_seasonal_mean_squared_error(head.toFfiSlice(), rows.toFfiSlice()).intoSwiftRepr()
}
public func flows_seasonal_tuned_rows(_ base_rows: Int64, _ has_base_rows: Bool, _ samples: Int64) -> Int64 {
    __swift_bridge__$flows_seasonal_tuned_rows(base_rows, has_base_rows, samples)
}
public func flows_seasonal_choose_head(_ has_local: Bool, _ local_rows: Int64, _ has_local_rows: Bool, _ local_tuned: Bool, _ has_local_tuned: Bool, _ has_bundled: Bool, _ bundled_rows: Int64, _ has_bundled_rows: Bool) -> UInt8 {
    __swift_bridge__$flows_seasonal_choose_head(has_local, local_rows, has_local_rows, local_tuned, has_local_tuned, has_bundled, bundled_rows, has_bundled_rows)
}
public func flows_seasonal_tune_due(_ total_trips: Int64, _ seconds_since_last_tune: Double, _ has_last_tune: Bool, _ tuned_at_trip_count: Int64) -> Bool {
    __swift_bridge__$flows_seasonal_tune_due(total_trips, seconds_since_last_tune, has_last_tune, tuned_at_trip_count)
}
public func flows_seasonal_accept_tune(_ tuned_mse: Double, _ base_mse: Double) -> Bool {
    __swift_bridge__$flows_seasonal_accept_tune(tuned_mse, base_mse)
}
public func flows_seasonal_blend_prior(_ modeled: Double, _ observed_risk: Double, _ confidence: Double) -> Double {
    __swift_bridge__$flows_seasonal_blend_prior(modeled, observed_risk, confidence)
}
public func flows_seasonal_week_of_year(_ ordinal_day: Int64, _ has_ordinal_day: Bool) -> Int64 {
    __swift_bridge__$flows_seasonal_week_of_year(ordinal_day, has_ordinal_day)
}
public struct FlowsSeasonalOptional {
    public var is_some: Double
    public var value: Double

    public init(is_some: Double,value: Double) {
        self.is_some = is_some
        self.value = value
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsSeasonalOptional {
        { let val = self; return __swift_bridge__$FlowsSeasonalOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$FlowsSeasonalOptional {
    @inline(__always)
    func intoSwiftRepr() -> FlowsSeasonalOptional {
        { let val = self; return FlowsSeasonalOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$Option$FlowsSeasonalOptional {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsSeasonalOptional> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsSeasonalOptional>) -> __swift_bridge__$Option$FlowsSeasonalOptional {
        if let v = val {
            return __swift_bridge__$Option$FlowsSeasonalOptional(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsSeasonalOptional(is_some: false, val: __swift_bridge__$FlowsSeasonalOptional())
        }
    }
}
public struct FlowsSeasonalWeekStat {
    public var w_sum: Double
    public var w_observed: Double
    public var w_sq_err: Double
    public var last_t: Double
    public var count: Int64

    public init(w_sum: Double,w_observed: Double,w_sq_err: Double,last_t: Double,count: Int64) {
        self.w_sum = w_sum
        self.w_observed = w_observed
        self.w_sq_err = w_sq_err
        self.last_t = last_t
        self.count = count
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsSeasonalWeekStat {
        { let val = self; return __swift_bridge__$FlowsSeasonalWeekStat(w_sum: val.w_sum, w_observed: val.w_observed, w_sq_err: val.w_sq_err, last_t: val.last_t, count: val.count); }()
    }
}
extension __swift_bridge__$FlowsSeasonalWeekStat {
    @inline(__always)
    func intoSwiftRepr() -> FlowsSeasonalWeekStat {
        { let val = self; return FlowsSeasonalWeekStat(w_sum: val.w_sum, w_observed: val.w_observed, w_sq_err: val.w_sq_err, last_t: val.last_t, count: val.count); }()
    }
}
extension __swift_bridge__$Option$FlowsSeasonalWeekStat {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsSeasonalWeekStat> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsSeasonalWeekStat>) -> __swift_bridge__$Option$FlowsSeasonalWeekStat {
        if let v = val {
            return __swift_bridge__$Option$FlowsSeasonalWeekStat(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsSeasonalWeekStat(is_some: false, val: __swift_bridge__$FlowsSeasonalWeekStat())
        }
    }
}
public struct FlowsSeasonalPrior {
    public var has: Double
    public var risk: Double
    public var confidence: Double

    public init(has: Double,risk: Double,confidence: Double) {
        self.has = has
        self.risk = risk
        self.confidence = confidence
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsSeasonalPrior {
        { let val = self; return __swift_bridge__$FlowsSeasonalPrior(has: val.has, risk: val.risk, confidence: val.confidence); }()
    }
}
extension __swift_bridge__$FlowsSeasonalPrior {
    @inline(__always)
    func intoSwiftRepr() -> FlowsSeasonalPrior {
        { let val = self; return FlowsSeasonalPrior(has: val.has, risk: val.risk, confidence: val.confidence); }()
    }
}
extension __swift_bridge__$Option$FlowsSeasonalPrior {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsSeasonalPrior> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsSeasonalPrior>) -> __swift_bridge__$Option$FlowsSeasonalPrior {
        if let v = val {
            return __swift_bridge__$Option$FlowsSeasonalPrior(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsSeasonalPrior(is_some: false, val: __swift_bridge__$FlowsSeasonalPrior())
        }
    }
}
public struct FlowsSeasonalOriginStat {
    public var weighted: Double
    public var last_seen: Double
    public var first_seen: Double
    public var trips: Int64

    public init(weighted: Double,last_seen: Double,first_seen: Double,trips: Int64) {
        self.weighted = weighted
        self.last_seen = last_seen
        self.first_seen = first_seen
        self.trips = trips
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsSeasonalOriginStat {
        { let val = self; return __swift_bridge__$FlowsSeasonalOriginStat(weighted: val.weighted, last_seen: val.last_seen, first_seen: val.first_seen, trips: val.trips); }()
    }
}
extension __swift_bridge__$FlowsSeasonalOriginStat {
    @inline(__always)
    func intoSwiftRepr() -> FlowsSeasonalOriginStat {
        { let val = self; return FlowsSeasonalOriginStat(weighted: val.weighted, last_seen: val.last_seen, first_seen: val.first_seen, trips: val.trips); }()
    }
}
extension __swift_bridge__$Option$FlowsSeasonalOriginStat {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsSeasonalOriginStat> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsSeasonalOriginStat>) -> __swift_bridge__$Option$FlowsSeasonalOriginStat {
        if let v = val {
            return __swift_bridge__$Option$FlowsSeasonalOriginStat(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsSeasonalOriginStat(is_some: false, val: __swift_bridge__$FlowsSeasonalOriginStat())
        }
    }
}
public struct FlowsSeasonalCell {
    public var has: Double
    public var lat: Int64
    public var lon: Int64

    public init(has: Double,lat: Int64,lon: Int64) {
        self.has = has
        self.lat = lat
        self.lon = lon
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsSeasonalCell {
        { let val = self; return __swift_bridge__$FlowsSeasonalCell(has: val.has, lat: val.lat, lon: val.lon); }()
    }
}
extension __swift_bridge__$FlowsSeasonalCell {
    @inline(__always)
    func intoSwiftRepr() -> FlowsSeasonalCell {
        { let val = self; return FlowsSeasonalCell(has: val.has, lat: val.lat, lon: val.lon); }()
    }
}
extension __swift_bridge__$Option$FlowsSeasonalCell {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsSeasonalCell> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsSeasonalCell>) -> __swift_bridge__$Option$FlowsSeasonalCell {
        if let v = val {
            return __swift_bridge__$Option$FlowsSeasonalCell(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsSeasonalCell(is_some: false, val: __swift_bridge__$FlowsSeasonalCell())
        }
    }
}
public struct FlowsSeasonalHome {
    public var has: Double
    public var lat: Double
    public var lon: Double
    public var trips: Int64

    public init(has: Double,lat: Double,lon: Double,trips: Int64) {
        self.has = has
        self.lat = lat
        self.lon = lon
        self.trips = trips
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsSeasonalHome {
        { let val = self; return __swift_bridge__$FlowsSeasonalHome(has: val.has, lat: val.lat, lon: val.lon, trips: val.trips); }()
    }
}
extension __swift_bridge__$FlowsSeasonalHome {
    @inline(__always)
    func intoSwiftRepr() -> FlowsSeasonalHome {
        { let val = self; return FlowsSeasonalHome(has: val.has, lat: val.lat, lon: val.lon, trips: val.trips); }()
    }
}
extension __swift_bridge__$Option$FlowsSeasonalHome {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsSeasonalHome> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsSeasonalHome>) -> __swift_bridge__$Option$FlowsSeasonalHome {
        if let v = val {
            return __swift_bridge__$Option$FlowsSeasonalHome(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsSeasonalHome(is_some: false, val: __swift_bridge__$FlowsSeasonalHome())
        }
    }
}


public func flows_tags_max_grade_percent(_ elevations: UnsafeBufferPointer<Double>, _ present: UnsafeBufferPointer<UInt8>, _ count: Int64, _ spacing_meters: Double) -> FlowsTagsNumber {
    __swift_bridge__$flows_tags_max_grade_percent(elevations.toFfiSlice(), present.toFfiSlice(), count, spacing_meters).intoSwiftRepr()
}
public func flows_tags_clearance_meters<GenericToRustStr: ToRustStr>(_ tag: GenericToRustStr) -> FlowsTagsNumber {
    return tag.toRustStr({ tagAsRustStr in
        __swift_bridge__$flows_tags_clearance_meters(tagAsRustStr).intoSwiftRepr()
    })
}
public func flows_tags_weight_limit_lbs<GenericToRustStr: ToRustStr>(_ tag: GenericToRustStr) -> FlowsTagsNumber {
    return tag.toRustStr({ tagAsRustStr in
        __swift_bridge__$flows_tags_weight_limit_lbs(tagAsRustStr).intoSwiftRepr()
    })
}
public func flows_tags_is_high_risk_flood_zone<GenericToRustStr: ToRustStr>(_ zone: GenericToRustStr) -> Bool {
    return zone.toRustStr({ zoneAsRustStr in
        __swift_bridge__$flows_tags_is_high_risk_flood_zone(zoneAsRustStr)
    })
}
public func flows_tags_route_constants() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_tags_route_constants())
}
public func flows_tags_parse_tpms<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr, _ has_name: Bool, _ data: UnsafeBufferPointer<UInt8>, _ data_count: Int64, _ has_data: Bool) -> RustVec<Double> {
    return name.toRustStr({ nameAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_tags_parse_tpms(nameAsRustStr, has_name, data.toFfiSlice(), data_count, has_data))
    })
}
public func flows_tags_tpms_position<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_tags_tpms_position(nameAsRustStr))
    })
}
public func flows_tags_displayed_psi(_ psi: Double) -> Double {
    __swift_bridge__$flows_tags_displayed_psi(psi)
}
public func flows_tags_parse_fuel_reply<GenericToRustStr: ToRustStr>(_ line: GenericToRustStr) -> FlowsTagsNumber {
    return line.toRustStr({ lineAsRustStr in
        __swift_bridge__$flows_tags_parse_fuel_reply(lineAsRustStr).intoSwiftRepr()
    })
}
public func flows_tags_looks_like_obd_adapter<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> Bool {
    return name.toRustStr({ nameAsRustStr in
        __swift_bridge__$flows_tags_looks_like_obd_adapter(nameAsRustStr)
    })
}
public func flows_tags_low_pressure_psi() -> Double {
    __swift_bridge__$flows_tags_low_pressure_psi()
}
public func flows_tags_interpret_yes_no<GenericToRustStr: ToRustStr>(_ transcript: GenericToRustStr) -> Int64 {
    return transcript.toRustStr({ transcriptAsRustStr in
        __swift_bridge__$flows_tags_interpret_yes_no(transcriptAsRustStr)
    })
}
public func flows_tags_wants_weather_radio<GenericToRustStr: ToRustStr>(_ transcript: GenericToRustStr) -> Bool {
    return transcript.toRustStr({ transcriptAsRustStr in
        __swift_bridge__$flows_tags_wants_weather_radio(transcriptAsRustStr)
    })
}
public func flows_tags_choose<GenericToRustStr: ToRustStr>(_ reply: GenericToRustStr, _ options: GenericToRustStr, _ option_lengths: UnsafeBufferPointer<Int64>, _ option_count: Int64) -> FlowsTagsOutcome {
    return options.toRustStr({ optionsAsRustStr in
        return reply.toRustStr({ replyAsRustStr in
        __swift_bridge__$flows_tags_choose(replyAsRustStr, optionsAsRustStr, option_lengths.toFfiSlice(), option_count).intoSwiftRepr()
    })
    })
}
public func flows_tags_place_reply<GenericToRustStr: ToRustStr>(_ reply: GenericToRustStr, _ places: GenericToRustStr, _ place_lengths: UnsafeBufferPointer<Int64>, _ place_count: Int64, _ cuisines: GenericToRustStr, _ cuisine_lengths: UnsafeBufferPointer<Int64>, _ cuisine_count: Int64) -> FlowsTagsOutcome {
    return cuisines.toRustStr({ cuisinesAsRustStr in
        return places.toRustStr({ placesAsRustStr in
        return reply.toRustStr({ replyAsRustStr in
        __swift_bridge__$flows_tags_place_reply(replyAsRustStr, placesAsRustStr, place_lengths.toFfiSlice(), place_count, cuisinesAsRustStr, cuisine_lengths.toFfiSlice(), cuisine_count).intoSwiftRepr()
    })
    })
    })
}
public func flows_tags_list_text(_ list: UInt16) -> RustString {
    RustString(ptr: __swift_bridge__$flows_tags_list_text(list))
}
public func flows_tags_list_lengths(_ list: UInt16) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_tags_list_lengths(list))
}
public func flows_tags_kind_for_tags<GenericToRustStr: ToRustStr>(_ tags: GenericToRustStr) -> Int64 {
    return tags.toRustStr({ tagsAsRustStr in
        __swift_bridge__$flows_tags_kind_for_tags(tagsAsRustStr)
    })
}
public func flows_tags_match_order() -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_tags_match_order())
}
public func flows_tags_dial_label<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_tags_dial_label(nameAsRustStr))
    })
}
public func flows_tags_ranked_stations(_ lats: UnsafeBufferPointer<Double>, _ has_lat: UnsafeBufferPointer<UInt8>, _ lons: UnsafeBufferPointer<Double>, _ has_lon: UnsafeBufferPointer<UInt8>, _ bitrates: UnsafeBufferPointer<Int64>, _ count: Int64, _ lat: Double, _ lon: Double, _ has_position: Bool) -> RustVec<Int64> {
    RustVec(ptr: __swift_bridge__$flows_tags_ranked_stations(lats.toFfiSlice(), has_lat.toFfiSlice(), lons.toFfiSlice(), has_lon.toFfiSlice(), bitrates.toFfiSlice(), count, lat, lon, has_position))
}
public func flows_tags_is_allowed_mirror<GenericToRustStr: ToRustStr>(_ host: GenericToRustStr) -> Bool {
    return host.toRustStr({ hostAsRustStr in
        __swift_bridge__$flows_tags_is_allowed_mirror(hostAsRustStr)
    })
}
public func flows_tags_nearby_radius_meters() -> Int64 {
    __swift_bridge__$flows_tags_nearby_radius_meters()
}
public func flows_tags_merged_stations<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ name_lengths: UnsafeBufferPointer<Int64>, _ urls: GenericToRustStr, _ url_lengths: UnsafeBufferPointer<Int64>, _ name_hit_count: Int64, _ has_name_hits: Bool, _ tag_hit_count: Int64, _ has_tag_hits: Bool) -> RustVec<Int64> {
    return urls.toRustStr({ urlsAsRustStr in
        return names.toRustStr({ namesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_tags_merged_stations(namesAsRustStr, name_lengths.toFfiSlice(), urlsAsRustStr, url_lengths.toFfiSlice(), name_hit_count, has_name_hits, tag_hit_count, has_tag_hits))
    })
    })
}
public func flows_tags_kept_station_rows<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ name_lengths: UnsafeBufferPointer<Int64>, _ has_name: UnsafeBufferPointer<UInt8>, _ urls: GenericToRustStr, _ url_lengths: UnsafeBufferPointer<Int64>, _ has_url: UnsafeBufferPointer<UInt8>, _ count: Int64) -> RustVec<Int64> {
    return urls.toRustStr({ urlsAsRustStr in
        return names.toRustStr({ namesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_tags_kept_station_rows(namesAsRustStr, name_lengths.toFfiSlice(), has_name.toFfiSlice(), urlsAsRustStr, url_lengths.toFfiSlice(), has_url.toFfiSlice(), count))
    })
    })
}
public func flows_tags_station_name<GenericToRustStr: ToRustStr>(_ name: GenericToRustStr) -> RustString {
    return name.toRustStr({ nameAsRustStr in
        RustString(ptr: __swift_bridge__$flows_tags_station_name(nameAsRustStr))
    })
}
public func flows_tags_unique_server_names<GenericToRustStr: ToRustStr>(_ names: GenericToRustStr, _ lengths: UnsafeBufferPointer<Int64>, _ present: UnsafeBufferPointer<UInt8>, _ count: Int64) -> RustVec<Int64> {
    return names.toRustStr({ namesAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_tags_unique_server_names(namesAsRustStr, lengths.toFfiSlice(), present.toFfiSlice(), count))
    })
}
public func flows_tags_genre_words<GenericToRustStr: ToRustStr>(_ tags: GenericToRustStr) -> RustString {
    return tags.toRustStr({ tagsAsRustStr in
        RustString(ptr: __swift_bridge__$flows_tags_genre_words(tagsAsRustStr))
    })
}
public func flows_tags_state_name<GenericToRustStr: ToRustStr>(_ code: GenericToRustStr) -> RustString {
    return code.toRustStr({ codeAsRustStr in
        RustString(ptr: __swift_bridge__$flows_tags_state_name(codeAsRustStr))
    })
}
public func flows_tags_ranked_nearest<GenericToRustStr: ToRustStr>(_ lats: UnsafeBufferPointer<Double>, _ has_lat: UnsafeBufferPointer<UInt8>, _ lons: UnsafeBufferPointer<Double>, _ has_lon: UnsafeBufferPointer<UInt8>, _ votes: UnsafeBufferPointer<Int64>, _ urls: GenericToRustStr, _ url_lengths: UnsafeBufferPointer<Int64>, _ count: Int64, _ lat: Double, _ lon: Double) -> RustVec<Int64> {
    return urls.toRustStr({ urlsAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_tags_ranked_nearest(lats.toFfiSlice(), has_lat.toFfiSlice(), lons.toFfiSlice(), has_lon.toFfiSlice(), votes.toFfiSlice(), urlsAsRustStr, url_lengths.toFfiSlice(), count, lat, lon))
    })
}
public struct FlowsTagsNumber {
    public var has: Bool
    public var value: Double

    public init(has: Bool,value: Double) {
        self.has = has
        self.value = value
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsTagsNumber {
        { let val = self; return __swift_bridge__$FlowsTagsNumber(has: val.has, value: val.value); }()
    }
}
extension __swift_bridge__$FlowsTagsNumber {
    @inline(__always)
    func intoSwiftRepr() -> FlowsTagsNumber {
        { let val = self; return FlowsTagsNumber(has: val.has, value: val.value); }()
    }
}
extension __swift_bridge__$Option$FlowsTagsNumber {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsTagsNumber> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsTagsNumber>) -> __swift_bridge__$Option$FlowsTagsNumber {
        if let v = val {
            return __swift_bridge__$Option$FlowsTagsNumber(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsTagsNumber(is_some: false, val: __swift_bridge__$FlowsTagsNumber())
        }
    }
}
public struct FlowsTagsOutcome {
    public var code: UInt8
    public var index: Int64

    public init(code: UInt8,index: Int64) {
        self.code = code
        self.index = index
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$FlowsTagsOutcome {
        { let val = self; return __swift_bridge__$FlowsTagsOutcome(code: val.code, index: val.index); }()
    }
}
extension __swift_bridge__$FlowsTagsOutcome {
    @inline(__always)
    func intoSwiftRepr() -> FlowsTagsOutcome {
        { let val = self; return FlowsTagsOutcome(code: val.code, index: val.index); }()
    }
}
extension __swift_bridge__$Option$FlowsTagsOutcome {
    @inline(__always)
    func intoSwiftRepr() -> Optional<FlowsTagsOutcome> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<FlowsTagsOutcome>) -> __swift_bridge__$Option$FlowsTagsOutcome {
        if let v = val {
            return __swift_bridge__$Option$FlowsTagsOutcome(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$FlowsTagsOutcome(is_some: false, val: __swift_bridge__$FlowsTagsOutcome())
        }
    }
}


public func flows_trip_vehicle_fuel_type_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_fuel_type_names())
}
public func flows_trip_vehicle_food_category_names() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_food_category_names())
}
public func flows_trip_vehicle_need_label(_ code: UInt8) -> RustString {
    RustString(ptr: __swift_bridge__$flows_trip_vehicle_need_label(code))
}
public func flows_trip_vehicle_default_miles_per_unit() -> Double {
    __swift_bridge__$flows_trip_vehicle_default_miles_per_unit()
}
public func flows_trip_vehicle_default_fuel_code() -> UInt8 {
    __swift_bridge__$flows_trip_vehicle_default_fuel_code()
}
public func flows_trip_vehicle_grams_co2_per_unit(_ fuel: UInt8) -> Double {
    __swift_bridge__$flows_trip_vehicle_grams_co2_per_unit(fuel)
}
public func flows_trip_vehicle_transit_grams_co2_per_mile(_ rail: Bool, _ long_haul: Bool) -> Double {
    __swift_bridge__$flows_trip_vehicle_transit_grams_co2_per_mile(rail, long_haul)
}
public func flows_trip_vehicle_drive_fuel_cost_usd(_ miles: Double, _ miles_per_unit: Double, _ price_per_unit: Double) -> TripVehicleOptional {
    __swift_bridge__$flows_trip_vehicle_drive_fuel_cost_usd(miles, miles_per_unit, price_per_unit).intoSwiftRepr()
}
public func flows_trip_vehicle_drive_grams_co2_per_mile(_ fuel: UInt8, _ miles_per_unit: Double) -> TripVehicleOptional {
    __swift_bridge__$flows_trip_vehicle_drive_grams_co2_per_mile(fuel, miles_per_unit).intoSwiftRepr()
}
public func flows_trip_vehicle_schedule(_ total_miles: Double, _ intervals: UnsafeBufferPointer<Double>, _ seed: UInt64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_schedule(total_miles, intervals.toFfiSlice(), seed))
}
public func flows_trip_vehicle_next_need_index(_ after_mile: Double, _ miles: UnsafeBufferPointer<Double>) -> Int32 {
    __swift_bridge__$flows_trip_vehicle_next_need_index(after_mile, miles.toFfiSlice())
}
public func flows_trip_vehicle_adjusted_remaining_seconds(_ baseline: Double, _ stop_delay_seconds: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_adjusted_remaining_seconds(baseline, stop_delay_seconds)
}
public func flows_trip_vehicle_splitmix64_initial_state(_ seed: UInt64) -> UInt64 {
    __swift_bridge__$flows_trip_vehicle_splitmix64_initial_state(seed)
}
public func flows_trip_vehicle_splitmix64_advance(_ state: UInt64) -> UInt64 {
    __swift_bridge__$flows_trip_vehicle_splitmix64_advance(state)
}
public func flows_trip_vehicle_splitmix64_mix(_ state: UInt64) -> UInt64 {
    __swift_bridge__$flows_trip_vehicle_splitmix64_mix(state)
}
public func flows_trip_vehicle_impact_g_force() -> Double {
    __swift_bridge__$flows_trip_vehicle_impact_g_force()
}
public func flows_trip_vehicle_hard_impact_g_force() -> Double {
    __swift_bridge__$flows_trip_vehicle_hard_impact_g_force()
}
public func flows_trip_vehicle_confirm_impact_g_force() -> Double {
    __swift_bridge__$flows_trip_vehicle_confirm_impact_g_force()
}
public func flows_trip_vehicle_min_pre_impact_speed_mps() -> Double {
    __swift_bridge__$flows_trip_vehicle_min_pre_impact_speed_mps()
}
public func flows_trip_vehicle_crash_stop_speed_mps() -> Double {
    __swift_bridge__$flows_trip_vehicle_crash_stop_speed_mps()
}
public func flows_trip_vehicle_min_speed_drop_fraction() -> Double {
    __swift_bridge__$flows_trip_vehicle_min_speed_drop_fraction()
}
public func flows_trip_vehicle_max_meters_from_road() -> Double {
    __swift_bridge__$flows_trip_vehicle_max_meters_from_road()
}
public func flows_trip_vehicle_assist_words() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_assist_words())
}
public func flows_trip_vehicle_ok_words() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_ok_words())
}
public func flows_trip_vehicle_is_impact_acceleration(_ acceleration_g: Double) -> Bool {
    __swift_bridge__$flows_trip_vehicle_is_impact_acceleration(acceleration_g)
}
public func flows_trip_vehicle_is_impact_window(_ window: UnsafeBufferPointer<Double>) -> Bool {
    __swift_bridge__$flows_trip_vehicle_is_impact_window(window.toFfiSlice())
}
public func flows_trip_vehicle_is_crash(_ window: UnsafeBufferPointer<Double>, _ speed_before_mps: Double, _ speed_after_mps: Double, _ meters_from_road: Double, _ has_meters_from_road: Bool) -> Bool {
    __swift_bridge__$flows_trip_vehicle_is_crash(window.toFfiSlice(), speed_before_mps, speed_after_mps, meters_from_road, has_meters_from_road)
}
public func flows_trip_vehicle_interpret_reply<GenericToRustStr: ToRustStr>(_ transcript: GenericToRustStr) -> Int32 {
    return transcript.toRustStr({ transcriptAsRustStr in
        __swift_bridge__$flows_trip_vehicle_interpret_reply(transcriptAsRustStr)
    })
}
public func flows_trip_vehicle_hos_break_due_seconds() -> Double {
    __swift_bridge__$flows_trip_vehicle_hos_break_due_seconds()
}
public func flows_trip_vehicle_hos_warn_before_break_seconds() -> Double {
    __swift_bridge__$flows_trip_vehicle_hos_warn_before_break_seconds()
}
public func flows_trip_vehicle_hos_daily_driving_limit_seconds() -> Double {
    __swift_bridge__$flows_trip_vehicle_hos_daily_driving_limit_seconds()
}
public func flows_trip_vehicle_hos_break_reset_seconds() -> Double {
    __swift_bridge__$flows_trip_vehicle_hos_break_reset_seconds()
}
public func flows_trip_vehicle_hos_status(_ driving_seconds: Double) -> TripVehicleHosStatus {
    __swift_bridge__$flows_trip_vehicle_hos_status(driving_seconds).intoSwiftRepr()
}
public func flows_trip_vehicle_spec_number_slots() -> UInt32 {
    __swift_bridge__$flows_trip_vehicle_spec_number_slots()
}
public func flows_trip_vehicle_spec_makes() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_spec_makes())
}
public func flows_trip_vehicle_spec_models() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_spec_models())
}
public func flows_trip_vehicle_spec_numbers() -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_spec_numbers())
}
public func flows_trip_vehicle_distinct_makes() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_trip_vehicle_distinct_makes())
}
public func flows_trip_vehicle_spec_rows_for_make<GenericToRustStr: ToRustStr>(_ make: GenericToRustStr) -> RustVec<Double> {
    return make.toRustStr({ makeAsRustStr in
        RustVec(ptr: __swift_bridge__$flows_trip_vehicle_spec_rows_for_make(makeAsRustStr))
    })
}
public func flows_trip_vehicle_spec_index<GenericToRustStr: ToRustStr>(_ make: GenericToRustStr, _ model: GenericToRustStr) -> Int32 {
    return model.toRustStr({ modelAsRustStr in
        return make.toRustStr({ makeAsRustStr in
        __swift_bridge__$flows_trip_vehicle_spec_index(makeAsRustStr, modelAsRustStr)
    })
    })
}
public func flows_trip_vehicle_minimum_height_feet() -> Double {
    __swift_bridge__$flows_trip_vehicle_minimum_height_feet()
}
public func flows_trip_vehicle_combined_miles_per_unit(_ city_mpu: Double, _ highway_mpu: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_combined_miles_per_unit(city_mpu, highway_mpu)
}
public func flows_trip_vehicle_rated_miles_per_unit(_ city_mpu: Double, _ highway_mpu: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_rated_miles_per_unit(city_mpu, highway_mpu)
}
public func flows_trip_vehicle_reserve_miles() -> Double {
    __swift_bridge__$flows_trip_vehicle_reserve_miles()
}
public func flows_trip_vehicle_efficiency_factor(_ average_speed_mph: Double, _ idle_fraction: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_efficiency_factor(average_speed_mph, idle_fraction)
}
public func flows_trip_vehicle_rated_range_miles(_ tank_capacity_units: Double, _ rated_miles_per_unit: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_rated_range_miles(tank_capacity_units, rated_miles_per_unit)
}
public func flows_trip_vehicle_miles_per_unit_at_speed(_ tank_capacity_units: Double, _ rated_miles_per_unit: Double, _ city_miles_per_unit: Double, _ has_city_miles_per_unit: Bool, _ highway_miles_per_unit: Double, _ has_highway_miles_per_unit: Bool, _ mph: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_miles_per_unit_at_speed(tank_capacity_units, rated_miles_per_unit, city_miles_per_unit, has_city_miles_per_unit, highway_miles_per_unit, has_highway_miles_per_unit, mph)
}
public func flows_trip_vehicle_effective_range_miles(_ tank_capacity_units: Double, _ rated_miles_per_unit: Double, _ city_miles_per_unit: Double, _ has_city_miles_per_unit: Bool, _ highway_miles_per_unit: Double, _ has_highway_miles_per_unit: Bool, _ average_speed_mph: Double, _ idle_fraction: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_effective_range_miles(tank_capacity_units, rated_miles_per_unit, city_miles_per_unit, has_city_miles_per_unit, highway_miles_per_unit, has_highway_miles_per_unit, average_speed_mph, idle_fraction)
}
public func flows_trip_vehicle_fuel_fraction_after(_ tank_capacity_units: Double, _ rated_miles_per_unit: Double, _ city_miles_per_unit: Double, _ has_city_miles_per_unit: Bool, _ highway_miles_per_unit: Double, _ has_highway_miles_per_unit: Bool, _ miles_since_fill: Double, _ average_speed_mph: Double, _ idle_fraction: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_fuel_fraction_after(tank_capacity_units, rated_miles_per_unit, city_miles_per_unit, has_city_miles_per_unit, highway_miles_per_unit, has_highway_miles_per_unit, miles_since_fill, average_speed_mph, idle_fraction)
}
public func flows_trip_vehicle_expected_range_miles(_ tank_capacity_units: Double, _ rated_miles_per_unit: Double, _ city_miles_per_unit: Double, _ has_city_miles_per_unit: Bool, _ highway_miles_per_unit: Double, _ has_highway_miles_per_unit: Bool, _ miles_since_fill: Double, _ average_speed_mph: Double, _ idle_fraction: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_expected_range_miles(tank_capacity_units, rated_miles_per_unit, city_miles_per_unit, has_city_miles_per_unit, highway_miles_per_unit, has_highway_miles_per_unit, miles_since_fill, average_speed_mph, idle_fraction)
}
public func flows_trip_vehicle_should_recommend_fuel(_ range_remaining_miles: Double, _ miles_to_next_station: Double, _ reserve_miles: Double) -> Bool {
    __swift_bridge__$flows_trip_vehicle_should_recommend_fuel(range_remaining_miles, miles_to_next_station, reserve_miles)
}
public func flows_trip_vehicle_restore_driving_accepts(_ average_speed_mph: Double, _ idle_fraction: Double) -> Bool {
    __swift_bridge__$flows_trip_vehicle_restore_driving_accepts(average_speed_mph, idle_fraction)
}
public func flows_trip_vehicle_restore_driving_idle(_ idle_fraction: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_restore_driving_idle(idle_fraction)
}
public func flows_trip_vehicle_record_fix(_ miles_since_fill: Double, _ average_speed_mph: Double, _ idle_fraction: Double, _ speed_mps: Double, _ delta_meters: Double, _ towing: Bool, _ towing_economy_factor: Double) -> TripVehicleHabits {
    __swift_bridge__$flows_trip_vehicle_record_fix(miles_since_fill, average_speed_mph, idle_fraction, speed_mps, delta_meters, towing, towing_economy_factor).intoSwiftRepr()
}
public func flows_trip_vehicle_store_expected_range_miles(_ tank_capacity_units: Double, _ rated_miles_per_unit: Double, _ city_miles_per_unit: Double, _ has_city_miles_per_unit: Bool, _ highway_miles_per_unit: Double, _ has_highway_miles_per_unit: Bool, _ miles_since_fill: Double, _ average_speed_mph: Double, _ idle_fraction: Double, _ telemetry_fuel_fraction: Double, _ has_telemetry_fuel_fraction: Bool, _ towing: Bool, _ towing_economy_factor: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_store_expected_range_miles(tank_capacity_units, rated_miles_per_unit, city_miles_per_unit, has_city_miles_per_unit, highway_miles_per_unit, has_highway_miles_per_unit, miles_since_fill, average_speed_mph, idle_fraction, telemetry_fuel_fraction, has_telemetry_fuel_fraction, towing, towing_economy_factor)
}
public func flows_trip_vehicle_epa_class_physical<GenericToRustStr: ToRustStr>(_ vclass: GenericToRustStr) -> TripVehicleClassPhysical {
    return vclass.toRustStr({ vclassAsRustStr in
        __swift_bridge__$flows_trip_vehicle_epa_class_physical(vclassAsRustStr).intoSwiftRepr()
    })
}
public func flows_trip_vehicle_epa_validated_tank(_ tank: Double, _ combined_mpu: Double) -> Double {
    __swift_bridge__$flows_trip_vehicle_epa_validated_tank(tank, combined_mpu)
}
public func flows_trip_vehicle_epa_fuel_type_code<GenericToRustStr: ToRustStr>(_ fuel: GenericToRustStr) -> UInt8 {
    return fuel.toRustStr({ fuelAsRustStr in
        __swift_bridge__$flows_trip_vehicle_epa_fuel_type_code(fuelAsRustStr)
    })
}
public struct TripVehicleOptional {
    public var is_some: Double
    public var value: Double

    public init(is_some: Double,value: Double) {
        self.is_some = is_some
        self.value = value
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$TripVehicleOptional {
        { let val = self; return __swift_bridge__$TripVehicleOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$TripVehicleOptional {
    @inline(__always)
    func intoSwiftRepr() -> TripVehicleOptional {
        { let val = self; return TripVehicleOptional(is_some: val.is_some, value: val.value); }()
    }
}
extension __swift_bridge__$Option$TripVehicleOptional {
    @inline(__always)
    func intoSwiftRepr() -> Optional<TripVehicleOptional> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<TripVehicleOptional>) -> __swift_bridge__$Option$TripVehicleOptional {
        if let v = val {
            return __swift_bridge__$Option$TripVehicleOptional(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$TripVehicleOptional(is_some: false, val: __swift_bridge__$TripVehicleOptional())
        }
    }
}
public struct TripVehicleHosStatus {
    public var code: Double
    public var seconds_until_due: Double

    public init(code: Double,seconds_until_due: Double) {
        self.code = code
        self.seconds_until_due = seconds_until_due
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$TripVehicleHosStatus {
        { let val = self; return __swift_bridge__$TripVehicleHosStatus(code: val.code, seconds_until_due: val.seconds_until_due); }()
    }
}
extension __swift_bridge__$TripVehicleHosStatus {
    @inline(__always)
    func intoSwiftRepr() -> TripVehicleHosStatus {
        { let val = self; return TripVehicleHosStatus(code: val.code, seconds_until_due: val.seconds_until_due); }()
    }
}
extension __swift_bridge__$Option$TripVehicleHosStatus {
    @inline(__always)
    func intoSwiftRepr() -> Optional<TripVehicleHosStatus> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<TripVehicleHosStatus>) -> __swift_bridge__$Option$TripVehicleHosStatus {
        if let v = val {
            return __swift_bridge__$Option$TripVehicleHosStatus(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$TripVehicleHosStatus(is_some: false, val: __swift_bridge__$TripVehicleHosStatus())
        }
    }
}
public struct TripVehicleHabits {
    public var miles_since_fill: Double
    public var average_speed_mph: Double
    public var idle_fraction: Double

    public init(miles_since_fill: Double,average_speed_mph: Double,idle_fraction: Double) {
        self.miles_since_fill = miles_since_fill
        self.average_speed_mph = average_speed_mph
        self.idle_fraction = idle_fraction
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$TripVehicleHabits {
        { let val = self; return __swift_bridge__$TripVehicleHabits(miles_since_fill: val.miles_since_fill, average_speed_mph: val.average_speed_mph, idle_fraction: val.idle_fraction); }()
    }
}
extension __swift_bridge__$TripVehicleHabits {
    @inline(__always)
    func intoSwiftRepr() -> TripVehicleHabits {
        { let val = self; return TripVehicleHabits(miles_since_fill: val.miles_since_fill, average_speed_mph: val.average_speed_mph, idle_fraction: val.idle_fraction); }()
    }
}
extension __swift_bridge__$Option$TripVehicleHabits {
    @inline(__always)
    func intoSwiftRepr() -> Optional<TripVehicleHabits> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<TripVehicleHabits>) -> __swift_bridge__$Option$TripVehicleHabits {
        if let v = val {
            return __swift_bridge__$Option$TripVehicleHabits(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$TripVehicleHabits(is_some: false, val: __swift_bridge__$TripVehicleHabits())
        }
    }
}
public struct TripVehicleClassPhysical {
    public var tank: Double
    public var height: Double
    public var gvwr: Double
    public var tow_capacity: Double

    public init(tank: Double,height: Double,gvwr: Double,tow_capacity: Double) {
        self.tank = tank
        self.height = height
        self.gvwr = gvwr
        self.tow_capacity = tow_capacity
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$TripVehicleClassPhysical {
        { let val = self; return __swift_bridge__$TripVehicleClassPhysical(tank: val.tank, height: val.height, gvwr: val.gvwr, tow_capacity: val.tow_capacity); }()
    }
}
extension __swift_bridge__$TripVehicleClassPhysical {
    @inline(__always)
    func intoSwiftRepr() -> TripVehicleClassPhysical {
        { let val = self; return TripVehicleClassPhysical(tank: val.tank, height: val.height, gvwr: val.gvwr, tow_capacity: val.tow_capacity); }()
    }
}
extension __swift_bridge__$Option$TripVehicleClassPhysical {
    @inline(__always)
    func intoSwiftRepr() -> Optional<TripVehicleClassPhysical> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<TripVehicleClassPhysical>) -> __swift_bridge__$Option$TripVehicleClassPhysical {
        if let v = val {
            return __swift_bridge__$Option$TripVehicleClassPhysical(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$TripVehicleClassPhysical(is_some: false, val: __swift_bridge__$TripVehicleClassPhysical())
        }
    }
}


public func flows_vehicle_policy_state_tolerance_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_state_tolerance_mph()
}
public func flows_vehicle_policy_excess_over_limit_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_excess_over_limit_mph()
}
public func flows_vehicle_policy_excess_absolute_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_excess_absolute_mph()
}
public func flows_vehicle_policy_speed_sign_tolerance_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_speed_sign_tolerance_mph()
}
public func flows_vehicle_policy_speed_sign_over_by_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_speed_sign_over_by_mph()
}
public func flows_vehicle_policy_pursuit_default_speed_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_pursuit_default_speed_mph()
}
public func flows_vehicle_policy_pursuit_minimum_radius_meters() -> Double {
    __swift_bridge__$flows_vehicle_policy_pursuit_minimum_radius_meters()
}
public func flows_vehicle_policy_pursuit_maximum_elapsed_seconds() -> Double {
    __swift_bridge__$flows_vehicle_policy_pursuit_maximum_elapsed_seconds()
}
public func flows_vehicle_policy_towing_economy_factor() -> Double {
    __swift_bridge__$flows_vehicle_policy_towing_economy_factor()
}
public func flows_vehicle_policy_filter_default_vehicle_height_meters() -> Double {
    __swift_bridge__$flows_vehicle_policy_filter_default_vehicle_height_meters()
}
public func flows_vehicle_policy_filter_default_max_grade_percent() -> Double {
    __swift_bridge__$flows_vehicle_policy_filter_default_max_grade_percent()
}
public func flows_vehicle_policy_filter_default_clearance_margin_meters() -> Double {
    __swift_bridge__$flows_vehicle_policy_filter_default_clearance_margin_meters()
}
public func flows_vehicle_policy_grade_degrees(_ percent: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_grade_degrees(percent)
}
public func flows_vehicle_policy_grade_steep_threshold_percent() -> Double {
    __swift_bridge__$flows_vehicle_policy_grade_steep_threshold_percent()
}
public func flows_vehicle_policy_grade_lookahead_miles() -> Double {
    __swift_bridge__$flows_vehicle_policy_grade_lookahead_miles()
}
public func flows_vehicle_policy_drive_idle_speed_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_idle_speed_mph()
}
public func flows_vehicle_policy_drive_default_efficient_cruise_mph() -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_default_efficient_cruise_mph()
}
public func flows_vehicle_policy_compass_points() -> RustVec<RustString> {
    RustVec(ptr: __swift_bridge__$flows_vehicle_policy_compass_points())
}
public func flows_vehicle_policy_estimated_limit_mph(_ speed_mph: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_estimated_limit_mph(speed_mph)
}
public func flows_vehicle_policy_effective_limit_mph(_ posted_limit_mph: Double, _ has_posted_limit_mph: Bool, _ speed_mph: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_effective_limit_mph(posted_limit_mph, has_posted_limit_mph, speed_mph)
}
public func flows_vehicle_policy_state_threshold_mph(_ posted_limit_mph: Double, _ has_posted_limit_mph: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_state_threshold_mph(posted_limit_mph, has_posted_limit_mph)
}
public func flows_vehicle_policy_federal_threshold_mph(_ posted_limit_mph: Double, _ has_posted_limit_mph: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_federal_threshold_mph(posted_limit_mph, has_posted_limit_mph)
}
public func flows_vehicle_policy_standing_code(_ speed_mph: Double, _ posted_limit_mph: Double, _ has_posted_limit_mph: Bool) -> UInt8 {
    __swift_bridge__$flows_vehicle_policy_standing_code(speed_mph, posted_limit_mph, has_posted_limit_mph)
}
public func flows_vehicle_policy_compass_point_index<GenericToRustStr: ToRustStr>(_ word: GenericToRustStr) -> Int32 {
    return word.toRustStr({ wordAsRustStr in
        __swift_bridge__$flows_vehicle_policy_compass_point_index(wordAsRustStr)
    })
}
public func flows_vehicle_policy_parse_maxspeed_mph<GenericToRustStr: ToRustStr>(_ raw: GenericToRustStr) -> Double {
    return raw.toRustStr({ rawAsRustStr in
        __swift_bridge__$flows_vehicle_policy_parse_maxspeed_mph(rawAsRustStr)
    })
}
public func flows_vehicle_policy_judge_code(_ speed_mph: Double, _ limit_mph: Double, _ has_limit_mph: Bool) -> UInt8 {
    __swift_bridge__$flows_vehicle_policy_judge_code(speed_mph, limit_mph, has_limit_mph)
}
public func flows_vehicle_policy_pursuit_radius_meters(_ elapsed_seconds: Double, _ speed_mph: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_pursuit_radius_meters(elapsed_seconds, speed_mph)
}
public func flows_vehicle_policy_towing_estimated_ratings(_ height_feet: Double, _ fuel_code: UInt8) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_vehicle_policy_towing_estimated_ratings(height_feet, fuel_code))
}
public func flows_vehicle_policy_towing_has_effective_gcwr(_ has_gvwr_lbs: Bool, _ has_tow_capacity_lbs: Bool, _ has_gcwr_lbs: Bool) -> Bool {
    __swift_bridge__$flows_vehicle_policy_towing_has_effective_gcwr(has_gvwr_lbs, has_tow_capacity_lbs, has_gcwr_lbs)
}
public func flows_vehicle_policy_towing_effective_gcwr_lbs(_ gvwr_lbs: Double, _ has_gvwr_lbs: Bool, _ tow_capacity_lbs: Double, _ has_tow_capacity_lbs: Bool, _ gcwr_lbs: Double, _ has_gcwr_lbs: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_towing_effective_gcwr_lbs(gvwr_lbs, has_gvwr_lbs, tow_capacity_lbs, has_tow_capacity_lbs, gcwr_lbs, has_gcwr_lbs)
}
public func flows_vehicle_policy_towing_check(_ vehicle_weight_lbs: Double, _ towed_weight_lbs: Double, _ gvwr_lbs: Double, _ has_gvwr_lbs: Bool, _ tow_capacity_lbs: Double, _ has_tow_capacity_lbs: Bool, _ gcwr_lbs: Double, _ has_gcwr_lbs: Bool) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_vehicle_policy_towing_check(vehicle_weight_lbs, towed_weight_lbs, gvwr_lbs, has_gvwr_lbs, tow_capacity_lbs, has_tow_capacity_lbs, gcwr_lbs, has_gcwr_lbs))
}
public func flows_vehicle_policy_degrees_to_percent(_ degrees: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_degrees_to_percent(degrees)
}
public func flows_vehicle_policy_passes_clearances(_ vehicle_height_meters: Double, _ clearance_margin_meters: Double, _ clearances_meters: UnsafeBufferPointer<Double>) -> Bool {
    __swift_bridge__$flows_vehicle_policy_passes_clearances(vehicle_height_meters, clearance_margin_meters, clearances_meters.toFfiSlice())
}
public func flows_vehicle_policy_passes_grade(_ max_grade_percent: Double, _ route_max_grade_percent: Double, _ has_route_max_grade_percent: Bool) -> Bool {
    __swift_bridge__$flows_vehicle_policy_passes_grade(max_grade_percent, route_max_grade_percent, has_route_max_grade_percent)
}
public func flows_vehicle_policy_passes_weight_limits(_ rig_weight_lbs: Double, _ has_rig_weight_lbs: Bool, _ limits_lbs: UnsafeBufferPointer<Double>) -> Bool {
    __swift_bridge__$flows_vehicle_policy_passes_weight_limits(rig_weight_lbs, has_rig_weight_lbs, limits_lbs.toFfiSlice())
}
public func flows_vehicle_policy_default_max_grade_degrees(_ published_max_grade_percent: Double, _ has_published_max_grade_percent: Bool, _ gvwr_lbs: Double, _ has_gvwr_lbs: Bool, _ tow_capacity_lbs: Double, _ has_tow_capacity_lbs: Bool, _ height_feet: Double, _ towing: Bool, _ trailer_weight_lbs: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_default_max_grade_degrees(published_max_grade_percent, has_published_max_grade_percent, gvwr_lbs, has_gvwr_lbs, tow_capacity_lbs, has_tow_capacity_lbs, height_feet, towing, trailer_weight_lbs)
}
public func flows_vehicle_policy_grade_segments(_ elevations: UnsafeBufferPointer<Double>, _ present: UnsafeBufferPointer<UInt8>, _ spacing_meters: Double, _ start_mile: Double) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_vehicle_policy_grade_segments(elevations.toFfiSlice(), present.toFfiSlice(), spacing_meters, start_mile))
}
public func flows_vehicle_policy_grade_steepest(_ segments: UnsafeBufferPointer<Double>, _ top: Int64) -> RustVec<Double> {
    RustVec(ptr: __swift_bridge__$flows_vehicle_policy_grade_steepest(segments.toFfiSlice(), top))
}
public func flows_vehicle_policy_grade_next_steep_index(_ mile: Double, _ segments: UnsafeBufferPointer<Double>, _ threshold_percent: Double, _ lookahead_miles: Double) -> Int64 {
    __swift_bridge__$flows_vehicle_policy_grade_next_steep_index(mile, segments.toFfiSlice(), threshold_percent, lookahead_miles)
}
public func flows_vehicle_policy_drive_drag_penalty(_ speed_mph: Double, _ efficient_cruise_mph: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_drag_penalty(speed_mph, efficient_cruise_mph)
}
public func flows_vehicle_policy_drive_grade_penalty(_ grade_percent: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_grade_penalty(grade_percent)
}
public func flows_vehicle_policy_drive_throttle_penalty(_ accel_mph_per_sec: Double) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_throttle_penalty(accel_mph_per_sec)
}
public func flows_vehicle_policy_drive_headwind_mph(_ wind_mph: Double, _ wind_from_degrees: Double, _ has_wind_from_degrees: Bool, _ heading_degrees: Double, _ has_heading_degrees: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_headwind_mph(wind_mph, wind_from_degrees, has_wind_from_degrees, heading_degrees, has_heading_degrees)
}
public func flows_vehicle_policy_drive_airspeed_mph(_ speed_mph: Double, _ wind_mph: Double, _ wind_from_degrees: Double, _ has_wind_from_degrees: Bool, _ heading_degrees: Double, _ has_heading_degrees: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_airspeed_mph(speed_mph, wind_mph, wind_from_degrees, has_wind_from_degrees, heading_degrees, has_heading_degrees)
}
public func flows_vehicle_policy_drive_drag_sensitivity(_ city_mpu: Double, _ has_city_mpu: Bool, _ highway_mpu: Double, _ has_highway_mpu: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_drag_sensitivity(city_mpu, has_city_mpu, highway_mpu, has_highway_mpu)
}
public func flows_vehicle_policy_drive_load_factor(_ loaded_weight_lbs: Double, _ has_loaded_weight_lbs: Bool, _ vehicle_weight_lbs: Double, _ has_vehicle_weight_lbs: Bool, _ towing: Bool, _ fuel_fraction: Double, _ has_fuel_fraction: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_load_factor(loaded_weight_lbs, has_loaded_weight_lbs, vehicle_weight_lbs, has_vehicle_weight_lbs, towing, fuel_fraction, has_fuel_fraction)
}
public func flows_vehicle_policy_drive_score(_ speed_mph: Double, _ accel_mph_per_sec: Double, _ grade_percent: Double, _ wind_mph: Double, _ wind_from_degrees: Double, _ has_wind_from_degrees: Bool, _ heading_degrees: Double, _ has_heading_degrees: Bool, _ efficient_cruise_mph: Double, _ city_mpu: Double, _ has_city_mpu: Bool, _ highway_mpu: Double, _ has_highway_mpu: Bool, _ loaded_weight_lbs: Double, _ has_loaded_weight_lbs: Bool, _ vehicle_weight_lbs: Double, _ has_vehicle_weight_lbs: Bool, _ towing: Bool, _ fuel_fraction: Double, _ has_fuel_fraction: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_score(speed_mph, accel_mph_per_sec, grade_percent, wind_mph, wind_from_degrees, has_wind_from_degrees, heading_degrees, has_heading_degrees, efficient_cruise_mph, city_mpu, has_city_mpu, highway_mpu, has_highway_mpu, loaded_weight_lbs, has_loaded_weight_lbs, vehicle_weight_lbs, has_vehicle_weight_lbs, towing, fuel_fraction, has_fuel_fraction)
}
public func flows_vehicle_policy_drive_verdict_code(_ speed_mph: Double, _ accel_mph_per_sec: Double, _ grade_percent: Double, _ wind_mph: Double, _ wind_from_degrees: Double, _ has_wind_from_degrees: Bool, _ heading_degrees: Double, _ has_heading_degrees: Bool, _ efficient_cruise_mph: Double, _ city_mpu: Double, _ has_city_mpu: Bool, _ highway_mpu: Double, _ has_highway_mpu: Bool, _ loaded_weight_lbs: Double, _ has_loaded_weight_lbs: Bool, _ vehicle_weight_lbs: Double, _ has_vehicle_weight_lbs: Bool, _ towing: Bool, _ fuel_fraction: Double, _ has_fuel_fraction: Bool) -> UInt8 {
    __swift_bridge__$flows_vehicle_policy_drive_verdict_code(speed_mph, accel_mph_per_sec, grade_percent, wind_mph, wind_from_degrees, has_wind_from_degrees, heading_degrees, has_heading_degrees, efficient_cruise_mph, city_mpu, has_city_mpu, highway_mpu, has_highway_mpu, loaded_weight_lbs, has_loaded_weight_lbs, vehicle_weight_lbs, has_vehicle_weight_lbs, towing, fuel_fraction, has_fuel_fraction)
}
public func flows_vehicle_policy_drive_efficient_cruise_mph(_ city_mpu: Double, _ has_city_mpu: Bool, _ highway_mpu: Double, _ has_highway_mpu: Bool) -> Double {
    __swift_bridge__$flows_vehicle_policy_drive_efficient_cruise_mph(city_mpu, has_city_mpu, highway_mpu, has_highway_mpu)
}


