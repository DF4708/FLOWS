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


