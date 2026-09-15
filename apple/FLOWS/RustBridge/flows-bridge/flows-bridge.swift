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


