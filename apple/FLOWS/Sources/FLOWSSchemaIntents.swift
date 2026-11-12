// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AppIntents
import Foundation
import GeoToolbox
import MapKit
import MediaIntents

// The iOS 27 Siri schemas (maps navigation + audio playback), next to the
// classic intents in FLOWSIntents.swift, which stay as they are for iOS 17
// to 26 and for the shortcuts people already made. Every path here lands on
// the same AppModel calls those intents use: a trip is planned and offered
// (nothing drives until the spoken "go ahead"), a stop goes through
// addStop, ending is the End button, and radio plays only stations from
// FLOWS's own lists. The rules live in Core/SiriSchemaRules.swift.
//
// Not adopted: reporting incidents (FLOWS takes no crowd reports), sharing
// an ETA, and music entities (no song, artist or playlist results to give).

/// A plain-words failure Siri reads out as it is.
@available(iOS 27.0, macOS 27.0, *)
private struct SchemaIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
    init(_ line: String) { localizedStringResource = "\(line)" }
}

// MARK: travel mode and road preferences

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .maps.transportType)
enum MapsTransportTypeEnum: String {
    case driving
    case walking

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .driving: "Drive",
        .walking: "Walk",
    ]

    var mode: SiriSchemaRules.TripMode { self == .walking ? .walking : .driving }

    init(_ mode: SiriSchemaRules.TripMode) { self = mode == .walking ? .walking : .driving }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .maps.navigationPreferences)
enum MapsNavigationPreferencesEnum: String {
    case avoidTolls
    case avoidHighways

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .avoidTolls: "No tolls",
        .avoidHighways: "No highways",
    ]

    var preference: SiriSchemaRules.TripPreference {
        switch self {
        case .avoidTolls: return .avoidTolls
        case .avoidHighways: return .avoidHighways
        }
    }

    init(_ preference: SiriSchemaRules.TripPreference) {
        switch preference {
        case .avoidTolls: self = .avoidTolls
        case .avoidHighways: self = .avoidHighways
        }
    }
}

// MARK: places

/// A place Siri names. Its identifier is its point and name
/// (SiriSchemaRules.placeID), so it means the same place when handed back.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .maps.place)
struct MapsPlaceEntity {
    static let defaultQuery = MapsPlaceEntityQuery()

    let id: String

    var place: PlaceDescriptor
    var name: String?
    var categories: [String]
    // FLOWS does not keep hours, open/closed, prices or ratings for places,
    // so those stay empty rather than guessed. The phone number is Apple's
    // own, when its lookup gave one.
    var operatingStatus: MapsOperatingStatusEnum?
    var operatingHours: MapsOperatingHoursEntity?
    var phoneNumber: String?
    var priceRange: MapsPriceRangeEnum?
    var ratings: [MapsRating]
    var amenities: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name ?? place.commonName ?? "Place")")
    }

    init?(
        place: PlaceDescriptor, coordinate: CLLocationCoordinate2D, name: String?,
        phoneNumber: String? = nil
    ) {
        guard let id = SiriSchemaRules.placeID(coordinate, name: name) else { return nil }
        self.id = id
        self.place = place
        self.name = name
        self.categories = []
        self.operatingStatus = nil
        self.operatingHours = nil
        self.phoneNumber = phoneNumber
        self.priceRange = nil
        self.ratings = []
        self.amenities = []
    }

    init?(coordinate: CLLocationCoordinate2D, name: String?) {
        self.init(
            place: PlaceDescriptor(representations: [.coordinate(coordinate)], commonName: name),
            coordinate: coordinate, name: name)
    }

    struct MapsPlaceEntityQuery: EntityQuery {
        func entities(for identifiers: [MapsPlaceEntity.ID]) async throws -> [MapsPlaceEntity] {
            identifiers.compactMap { id in
                SiriSchemaRules.place(fromID: id).flatMap {
                    MapsPlaceEntity(coordinate: $0.coordinate, name: $0.name)
                }
            }
        }
    }
}

/// The places Siri means by a description: its point when it carries one,
/// else Apple's own lookup of it, else one search for its address or name
/// near the driver. One request at most per step, five places at most.
@available(iOS 27.0, macOS 27.0, *)
struct MapsPlaceEntityIntentValueQuery: IntentValueQuery {
    static let maxPlaces = 5

    // On the main actor: the search reads the trip and hands back map items,
    // which may not cross actors.
    @MainActor
    func values(for input: PlaceDescriptor) async throws -> [MapsPlaceEntity] {
        if let c = input.coordinate, SiriSchemaRules.isValid(c) {
            return [MapsPlaceEntity(place: input, coordinate: c, name: input.commonName)].compactMap { $0 }
        }
        if let item = try? await MKMapItemRequest(placeDescriptor: input).mapItem,
            let entity = MapsPlaceEntity(
                place: PlaceDescriptor(item: item) ?? input,
                coordinate: item.location.coordinate,
                name: item.name ?? input.commonName,
                phoneNumber: item.phoneNumber)
        {
            return [entity]
        }
        guard let words = input.address ?? input.commonName, !words.isEmpty else { return [] }
        let items = await searchPlaces(words)
        return items.prefix(Self.maxPlaces).compactMap { item in
            MapsPlaceEntity(
                place: PlaceDescriptor(item: item)
                    ?? PlaceDescriptor(
                        representations: [.coordinate(item.location.coordinate)],
                        commonName: item.name),
                coordinate: item.location.coordinate, name: item.name,
                phoneNumber: item.phoneNumber)
        }
    }
}

// The place schema's detail fields. FLOWS never fills them (see above);
// they exist because the schema lists them.

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .maps.operatingStatus)
enum MapsOperatingStatusEnum: String {
    case open
    case closed

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .open: "Open",
        .closed: "Closed",
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .maps.priceRange)
enum MapsPriceRangeEnum: String {
    case low
    case medium
    case high

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .low: "$",
        .medium: "$$",
        .high: "$$$",
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .maps.ratingDescriptor)
enum MapsRatingDescriptor: String {
    case percentage

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .percentage: "Percent"
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .maps.rating)
struct MapsRating: TransientAppEntity {
    var value: Double
    var descriptor: MapsRatingDescriptor
    var count: Int?
    var provider: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(Int(value.rounded()))%")
    }

    init() {
        value = 0
        descriptor = .percentage
        count = nil
        provider = ""
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .maps.operatingTimeRange)
struct MapsOperatingTimeRangeEntity: TransientAppEntity {
    var startTime: DateComponents
    var endTime: DateComponents

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Open hours")
    }

    init() {
        startTime = DateComponents()
        endTime = DateComponents()
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .maps.operatingHours)
struct MapsOperatingHoursEntity: TransientAppEntity {
    var monday: [MapsOperatingTimeRangeEntity]
    var tuesday: [MapsOperatingTimeRangeEntity]
    var wednesday: [MapsOperatingTimeRangeEntity]
    var thursday: [MapsOperatingTimeRangeEntity]
    var friday: [MapsOperatingTimeRangeEntity]
    var saturday: [MapsOperatingTimeRangeEntity]
    var sunday: [MapsOperatingTimeRangeEntity]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Open hours")
    }

    init() {
        monday = []
        tuesday = []
        wednesday = []
        thursday = []
        friday = []
        saturday = []
        sunday = []
    }
}

/// One search for spoken words, near the driver as StartTripIntent searches.
/// On a trip, places ahead on the road come first, found the way
/// AddPlaceStopIntent finds them: "a gas station" asked while driving means
/// one on the way, and the search around the driver put ones behind first.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
private func searchPlaces(_ words: String) async -> [MKMapItem] {
    let term = String(words.prefix(SiriSchemaRules.maxNameLength))
    let model = AppModel.shared
    if let model, model.mode == .navigating, let position = model.effectivePosition {
        let ahead = await model.poi.namedStops(term, aheadOf: position)
        if !ahead.isEmpty { return ahead }
    }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = term
    if let center = model.flatMap({ $0.effectivePosition ?? $0.bestKnownPosition?.coordinate }) {
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: 400_000, longitudinalMeters: 400_000)
    }
    return (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
}

/// Where Siri's place is: its own point, or Apple's lookup of it.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
private func coordinate(of entity: MapsPlaceEntity) async -> CLLocationCoordinate2D? {
    if let c = entity.place.coordinate, SiriSchemaRules.isValid(c) { return c }
    if let item = try? await MKMapItemRequest(placeDescriptor: entity.place).mapItem {
        return item.location.coordinate
    }
    return SiriSchemaRules.place(fromID: entity.id)?.coordinate
}

/// "Here": wherever the driver is when the trip is planned.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .maps.currentLocation)
struct MapsCurrentLocationEntity: UniqueAppEntity {
    static let defaultQuery = UniqueAppEntityProvider { MapsCurrentLocationEntity() }

    let id = "here"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Where you are")
    }
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum MapsLocation {
    case place(MapsPlaceEntity)
    case currentLocation(MapsCurrentLocationEntity)
}

// MARK: the trip

/// The trip being driven. There is only ever one, and none at all when
/// nothing is being driven (Siri is told so in plain words).
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .maps.navigationSession)
struct MapsNavigationSessionEntity: UniqueAppEntity {
    static let defaultQuery = MapsNavigationSessionEntityQuery()

    let id = "trip"

    var estimatedArrivalDate: Date
    var waypoints: [MapsLocation]
    var transportationType: MapsTransportTypeEnum
    var preferences: [MapsNavigationPreferencesEnum]

    /// The name the drive screen shows for where the trip ends.
    var destinationName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Trip to \(destinationName)",
            subtitle: "Arrives \(estimatedArrivalDate.formatted(date: .omitted, time: .shortened))")
    }

    init(
        estimatedArrivalDate: Date, waypoints: [MapsLocation],
        transportationType: MapsTransportTypeEnum,
        preferences: [MapsNavigationPreferencesEnum], destinationName: String
    ) {
        // The plain field first: the schema fields are wrapped properties,
        // and setting one needs every plain field already set.
        self.destinationName = destinationName
        self.estimatedArrivalDate = estimatedArrivalDate
        self.waypoints = waypoints
        self.transportationType = transportationType
        self.preferences = preferences
    }

    /// The live trip, or nil when none is being driven. Its stops are the
    /// end of the leg being driven (an added stop, or the destination) and,
    /// after an added stop, the destination the way on leads to.
    @MainActor
    static func current() -> MapsNavigationSessionEntity? {
        guard let model = AppModel.shared, model.mode == .navigating,
            let leg = model.navigation.route
        else { return nil }
        let legs = [leg] + [model.upcomingLeg].compactMap { $0 }
        let stops: [MapsLocation] = legs.compactMap { leg in
            legEnd(leg).flatMap { MapsPlaceEntity(coordinate: $0, name: leg.destinationName) }
                .map { .place($0) }
        }
        let seconds = model.tripRemaining?.seconds ?? leg.eta
        return MapsNavigationSessionEntity(
            estimatedArrivalDate: Date().addingTimeInterval(seconds),
            waypoints: stops,
            transportationType: MapsTransportTypeEnum(.init(walking: model.walkingMode)),
            preferences: SiriSchemaRules.preferences(in: model.routeFilters).map { .init($0) },
            destinationName: legs.last?.destinationName ?? leg.destinationName)
    }

    /// Where each stop already on the trip is, for SiriSchemaRules.newWaypoints.
    var stopCoordinates: [CLLocationCoordinate2D] {
        waypoints.compactMap {
            guard case .place(let p) = $0 else { return nil }
            return p.place.coordinate ?? SiriSchemaRules.place(fromID: p.id)?.coordinate
        }
    }

    struct MapsNavigationSessionEntityQuery: UniqueAppEntityQuery {
        func uniqueEntity() async throws -> MapsNavigationSessionEntity {
            guard let trip = await MapsNavigationSessionEntity.current() else {
                throw SchemaIntentError("No trip is under way. Start a route first.")
            }
            return trip
        }
    }
}

/// The last point of a leg's line: where that leg ends.
@available(iOS 27.0, macOS 27.0, *)
private func legEnd(_ leg: PlannedRoute) -> CLLocationCoordinate2D? {
    let poly = leg.route.polyline
    let n = poly.pointCount
    guard n > 0 else { return nil }
    return poly.coordinate(at: n - 1)
}

// MARK: start, add a stop, end

/// "Take me to the airport": the same plan-and-offer as StartTripIntent.
/// The routes show on screen and the first is offered out loud; nothing
/// drives until the driver says go ahead, so no trip comes back to Siri.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .maps.startNavigation)
struct MapsStartNavigationIntent {
    static let openAppWhenRun = true

    var transportationType: MapsTransportTypeEnum
    var origin: MapsLocation
    var destinations: [MapsLocation]
    var preferences: Set<MapsNavigationPreferencesEnum>

    @MainActor
    func perform() async throws -> some ReturnsValue<MapsNavigationSessionEntity?> & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(value: nil, dialog: "Open FLOWS first.")
        }
        // FLOWS plans to one place. The last one asked is where the trip
        // ends; the ones before it are stops to add once it is driving.
        guard case .place(let target)? = destinations.last else {
            return .result(value: nil, dialog: "Tell me where to go.")
        }
        guard let to = await coordinate(of: target) else {
            return .result(
                value: nil,
                dialog: IntentDialog(
                    "Couldn't find \(target.name ?? "that place")."))
        }
        let name = target.name ?? target.place.commonName ?? "your stop"
        let start: (coordinate: CLLocationCoordinate2D, label: String)
        switch origin {
        case .place(let from):
            // A trip under way starts where the driver is. A route from
            // somewhere else, said yes to, would take the live trip's place.
            guard !model.tripUnderway else {
                return .result(value: nil, dialog: "You're on a trip now. End it first, then ask again.")
            }
            guard let c = await coordinate(of: from) else {
                return .result(
                    value: nil,
                    dialog: IntentDialog(
                        "Couldn't find \(from.name ?? "where to start")."))
            }
            start = (c, from.name ?? from.place.commonName ?? "that place")
        case .currentLocation:
            // No fix → the planner's own fallback start (Home, or the usual
            // area), as the "From:" row shows it.
            guard
                let here = model.effectivePosition.map({ (coordinate: $0, label: "Current location") })
                    ?? model.bestKnownPosition
            else {
                return .result(value: nil, dialog: "I need a location fix first — open FLOWS.")
            }
            start = here
        }
        // A new mode or road choice re-plans what is on screen; under a
        // live trip that would replan the road being driven, so it waits.
        let walkingBefore = model.walkingMode
        let filtersBefore = model.routeFilters
        switch SiriSchemaRules.tripRequest(
            mode: transportationType.mode, preferences: Set(preferences.map(\.preference)),
            walkingNow: model.walkingMode, filters: model.routeFilters,
            tripUnderway: model.tripUnderway)
        {
        case .finishTripFirst:
            return .result(value: nil, dialog: "You're on a trip now. End it first, then ask again.")
        case .plan(let walking, let addFilters):
            if let walking { model.walkingMode = walking }
            if !addFilters.isEmpty { model.routeFilters.formUnion(addFilters) }
        }
        // A plan that comes to nothing puts the mode and the road choices
        // back: "walk to Denver" that found no way left Walk on, and the next
        // trip planned on foot. Only what this request set is undone; a
        // switch made on screen meanwhile is the driver's and stays.
        let askedWalking = model.walkingMode
        let askedFilters = model.routeFilters
        func putBack() {
            if model.walkingMode == askedWalking, askedWalking != walkingBefore {
                model.walkingMode = walkingBefore
            }
            if model.routeFilters == askedFilters, askedFilters != filtersBefore {
                model.routeFilters = filtersBefore
            }
        }
        let routes: [PlannedRoute]
        do {
            routes = try await model.plan(
                from: start.coordinate, fromName: start.label,
                to: to, toName: name)
        } catch is CancellationError {
            // Walk or Drive was switched on screen while this planned.
            return .result(
                value: nil,
                dialog: IntentDialog(
                    "The trip changed on screen while I planned. Ask me again."))
        } catch {
            // The router did not answer: that is not "no road goes there".
            putBack()
            return .result(
                value: nil,
                dialog: IntentDialog(
                    "I couldn't plan that right now. Check the connection and ask again."))
        }
        guard !routes.isEmpty else {
            putBack()
            return .result(value: nil, dialog: IntentDialog("No route found to \(name)."))
        }
        // present(routes:) is the one way in to the choices (see
        // StartTripIntent); the staged route is the one the list leads with.
        model.present(routes: routes)
        guard let staged = model.stageTripOffer(name: name) else {
            return .result(value: nil, dialog: IntentDialog("No route found to \(name)."))
        }
        let startNote: String
        switch start.label {
        case "Current location": startNote = ""
        case "Home": startNote = " from Home"
        case "Your usual area": startNote = " from your usual area"
        default: startNote = " from " + start.label
        }
        var summary = SiriSummaries.tripOffer(
            name: name + startNote, meters: staged.distanceMeters, seconds: staged.eta,
            whileDriving: model.tripUnderway)
        if destinations.count > 1 {
            summary += " Once you're driving, ask me to add the other stops."
        }
        return .result(value: nil, dialog: IntentDialog("\(summary)"))
    }
}

/// "Add a gas station to my route": the first place Siri asks for that is
/// not already on the trip becomes the next stop, through addStop, as
/// AddPlaceStopIntent does. FLOWS keeps one added stop at a time.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .maps.updateNavigationWaypoints)
struct MapsUpdateNavigationWaypointsIntent {
    static let openAppWhenRun = true

    var navigation: MapsNavigationSessionEntity
    var waypoints: [MapsLocation]

    @MainActor
    func perform() async throws -> some ReturnsValue<MapsNavigationSessionEntity> & ProvidesDialog {
        guard let model = AppModel.shared else { throw SchemaIntentError("Open FLOWS first.") }
        guard model.mode == .navigating, let position = model.effectivePosition,
            let trip = MapsNavigationSessionEntity.current()
        else {
            throw SchemaIntentError("Start a route first — then I can add a stop to it.")
        }
        var asked: [(entity: MapsPlaceEntity, coordinate: CLLocationCoordinate2D)] = []
        for case .place(let p) in waypoints.prefix(SiriSchemaRules.maxWaypoints) {
            if let c = await coordinate(of: p) { asked.append((p, c)) }
        }
        let fresh = SiriSchemaRules.newWaypoints(
            asked.map(\.coordinate),
            existing: trip.stopCoordinates)
        // None of the places could be found: "already on your trip" was
        // said for a stop FLOWS never looked up.
        guard !asked.isEmpty else {
            return .result(value: trip, dialog: "Couldn't find that place.")
        }
        guard let first = fresh.first else {
            // Siri may also send the list with a stop left out.
            return .result(
                value: trip,
                dialog:
                    "That's already on your trip. I can add a stop, but I can't take one off.")
        }
        let pick = asked[first]
        let name = pick.entity.name ?? pick.entity.place.commonName ?? "Stop"
        // Apple's own record of the place when it has one (a gas station
        // stays a gas station for the fuel range); a plain pin otherwise.
        let item: MKMapItem
        if let found = try? await MKMapItemRequest(placeDescriptor: pick.entity.place).mapItem {
            item = found
        } else {
            item = MKMapItem(
                location: CLLocation(
                    latitude: pick.coordinate.latitude,
                    longitude: pick.coordinate.longitude),
                address: nil)
        }
        item.name = name
        guard await model.addStop(item) else {
            return .result(
                value: MapsNavigationSessionEntity.current() ?? trip,
                dialog: IntentDialog(
                    "Couldn't route to \(name) right now. Try again in a moment."))
        }
        var line = SiriSummaries.addedStop(
            name: name,
            meters: POIRanking.meters(position, pick.coordinate))
        if fresh.count > 1 {
            line += " I add one stop at a time. Ask me for the next one after this."
        }
        return .result(
            value: MapsNavigationSessionEntity.current() ?? trip,
            dialog: IntentDialog("\(line)"))
    }
}

/// "Stop navigation": the drive screen's End button.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .maps.stopNavigation)
struct StopNavigationIntent {
    var navigation: MapsNavigationSessionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared, model.mode == .navigating else {
            return .result(dialog: "No trip is under way.")
        }
        model.endNavigation()
        return .result(dialog: "Trip ended.")
    }
}

// MARK: radio

/// An AM/FM station from the radio directory, or a NOAA weather radio
/// relay. Only ever one FLOWS found itself: the identifier picks a station
/// from FLOWS's lists and never brings a stream of its own.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.liveRadioStation)
struct LiveRadioStationEntity {
    static let defaultQuery = LiveRadioStationEntityQuery()

    let id: String

    var title: String
    var providerName: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(providerName ?? "Radio")")
    }

    init(ref: SiriSchemaRules.StationRef, title: String) {
        id = ref.id
        self.title = title
        switch ref {
        case .directory: providerName = "Radio station"
        case .weather: providerName = "NOAA Weather Radio"
        }
    }

    /// By identifier (a station FLOWS offered), or by name: the same search
    /// the radio screen's station search runs.
    struct LiveRadioStationEntityQuery: EntityStringQuery {
        func entities(matching string: String) async throws -> [LiveRadioStationEntity] {
            let words = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return [] }
            return await StationLookup.stations(for: words)
        }

        func entities(for identifiers: [LiveRadioStationEntity.ID]) async throws -> [LiveRadioStationEntity] {
            await MainActor.run {
                identifiers.prefix(SiriSchemaRules.maxStations).compactMap { id in
                    guard let ref = SiriSchemaRules.StationRef(id: id),
                        let channel = StationLookup.channel(for: ref)
                    else { return nil }
                    return LiveRadioStationEntity(ref: ref, title: channel.name)
                }
            }
        }
    }
}

/// The stations FLOWS last offered Siri, so one it offered still plays if
/// the radio screen searched for something else in between.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
private enum StationLookup {
    static var offered: [String: TruckerRadio.Channel] = [:]

    static func channel(for ref: SiriSchemaRules.StationRef) -> TruckerRadio.Channel? {
        if let hit = offered[ref.id] { return hit }
        guard let model = AppModel.shared else { return nil }
        switch ref {
        case .directory(let url):
            return model.radioBrowser.stations.first { $0.url == url }?.channel
                ?? model.radio.queue.first { $0.url == url }
                ?? model.radio.lastPlayed.flatMap { $0.url == url ? $0 : nil }
        case .weather(let name):
            return model.radio.channels.first { $0.name == name }
        }
    }

    /// The stations for what was asked: the nearest weather radio for a
    /// weather ask, else the directory's search, best names first.
    static func stations(for text: String) async -> [LiveRadioStationEntity] {
        guard let model = AppModel.shared else { return [] }
        var found: [(ref: SiriSchemaRules.StationRef, channel: TruckerRadio.Channel)] = []
        if SiriSchemaRules.wantsWeatherRadio(text) {
            let channel =
                model.effectivePosition
                .flatMap { model.radio.nearestChannel(to: $0)?.channel }
                ?? model.radio.nearestChannel(stateCode: model.currentStateCode)
            if let channel { found = [(.weather(name: channel.name), channel)] }
        } else {
            let ask = String(text.prefix(SiriSchemaRules.maxNameLength))
            await model.radioBrowser.search(text: ask)
            let stations = model.radioBrowser.stations
            found = SiriSchemaRules.rankStations(names: stations.map(\.name), query: ask)
                .map { (.directory(url: stations[$0].url), stations[$0].channel) }
        }
        offered = Dictionary(found.map { ($0.ref.id, $0.channel) }, uniquingKeysWith: { a, _ in a })
        return found.map { LiveRadioStationEntity(ref: $0.ref, title: $0.channel.name) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
enum AudioItem {
    case liveRadioStation(LiveRadioStationEntity)
}

/// What Siri heard asked for ("play WXPN", "play the weather radio"),
/// answered with FLOWS's own stations. A link or a bare "play something"
/// gets none: those stay with the music shortcut.
@available(iOS 27.0, macOS 27.0, *)
struct AudioItemIntentValueQuery: IntentValueQuery {
    func values(for input: AudioSearch) async throws -> [AudioItem] {
        switch input.criteria {
        case .searchQuery(let text):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return [] }
            return await StationLookup.stations(for: words).map { .liveRadioStation($0) }
        default:
            return []
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum PlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum QueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next",
        .tail: "Play Last",
    ]
}

/// Siri's note that it got the player ready ahead of time. The radio
/// starts a stream when asked, so FLOWS has nothing to get ready.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Ready to play")
    }

    init() {}
}

/// "Play the weather radio": tunes the station through the radio player,
/// as RadioControlIntent does. Live radio has no shuffle or repeat, and it
/// cannot wait its turn in a line, so "play it next" is answered, not faked.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent {
    var audioEntity: AudioItem
    var playbackAttributes: Set<PlaybackAttributes>
    var warmupAudioQueueResult: WarmupAudioQueueResult?
    var queueLocation: QueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else {
            return .result(dialog: "Open FLOWS first.")
        }
        if queueLocation != nil {
            return .result(dialog: "Live radio plays right away. Ask me to play it now.")
        }
        switch audioEntity {
        case .liveRadioStation(let station):
            guard let ref = SiriSchemaRules.StationRef(id: station.id),
                let channel = StationLookup.channel(for: ref)
            else {
                return .result(dialog: "That station isn't in FLOWS's list now. Ask me again.")
            }
            model.radio.play(channel)
            return .result(dialog: IntentDialog("Playing \(channel.name)."))
        }
    }
}
