// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit

/// Stops along the corridor, from Apple Maps (MKLocalSearch) — ranked by
/// POIRanking so results are ahead of the vehicle, on-corridor, and ordered
/// the way a driver decides:
///   Food → cuisine category first, then soonest-reachable restaurants.
///   Gas  → remembered fuel type (electric/gas/diesel), stations ranked by
///          fill cost + detour time (cheaper fuel justifies a longer detour).
@MainActor
final class POIService: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case gas = "Fuel"
        case food = "Food"
        case stores = "Stores"
        case tourist = "Tourist"
        case rest = "Rest"
        case hotel = "Hotels"
        case medical = "Medical"
        case shelter = "Shelter"
        case gyms = "Gyms"
        // Trucker-mode kinds.
        case shower = "Showers"
        case truckParking = "Truck parking"
        case parking = "Parking"
        case weighStation = "Weigh station"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .gas: return "fuelpump.fill"
            case .food: return "fork.knife"
            case .stores: return "bag.fill"
            case .tourist: return "star.fill"
            case .rest: return "chair.lounge.fill"
            case .hotel: return "bed.double.fill"
            case .medical: return "cross.case.fill"
            case .shelter: return "house.lodge.fill"
            case .gyms: return "dumbbell.fill"
            case .shower: return "shower.fill"
            case .truckParking: return "truck.box.fill"
            case .parking: return "parkingsign"
            case .weighStation: return "scalemass.fill"
            }
        }

        /// The bottom-bar button sets per mode.
        static let standardKinds: [Kind] = [.gas, .food, .stores, .rest, .parking,
                                            .hotel, .gyms, .medical, .shelter]
        // Stores sits before hotel/food so it never scrolls out of first view
        // on the wider trucker bar (it was technically present but off-screen).
        static let truckerKinds: [Kind] = [.gas, .shower, .truckParking, .weighStation,
                                           .stores, .rest, .hotel, .food, .medical,
                                           .shelter]
    }

    /// Category constraint per kind — review finding: the natural-language
    /// query alone let MKLocalSearch return name matches ("Hospital Bar &
    /// Grill" for Medical). Rest areas and shelters have no MK category, so
    /// those stay query-only.
    private static func poiFilter(for kind: Kind, fuel: FuelType?) -> MKPointOfInterestFilter? {
        switch kind {
        case .gas:
            return MKPointOfInterestFilter(
                including: fuel == .electric ? [.evCharger] : [.gasStation])
        case .food:
            return MKPointOfInterestFilter(
                including: [.restaurant, .cafe, .bakery, .foodMarket])
        case .stores:
            // No category filter: retail spans MK categories inconsistently
            // (AutoZone ≠ .store; some chains carry no category at all), and
            // the [.store, .foodMarket] filter silently dropped Best Buy /
            // AutoZone / Publix. The brand-augmented queries constrain instead.
            return nil
        case .tourist:
            return MKPointOfInterestFilter(
                including: [.nationalPark, .museum, .amusementPark, .zoo, .aquarium])
        case .medical:
            return MKPointOfInterestFilter(including: [.hospital, .pharmacy])
        case .hotel:
            return MKPointOfInterestFilter(including: [.hotel])
        case .shower:
            // No category filter: travel centers are tagged inconsistently
            // (some .gasStation, some .store, some nothing), and the filter
            // silently dropped the very truck stops that HAVE showers. The
            // brand-and-term queries constrain instead.
            return nil
        case .parking:
            return MKPointOfInterestFilter(including: [.parking])
        case .gyms:
            return MKPointOfInterestFilter(including: [.fitnessCenter])
        case .rest, .shelter, .truckParking, .weighStation:
            // No MK category models rest areas, shelters, truck parking, or
            // weigh stations.
            return nil
        }
    }

    /// Kind → offline shard group byte(s) (PlacesStore stays Kind-agnostic).
    static func shardGroups(for kind: Kind) -> Set<UInt8>? {
        let bits = kind.policy.shard_groups
        guard bits != 0 else { return nil }   // not in the dataset
        return Set((0..<32).filter { bits & (1 << $0) != 0 }.map { UInt8($0) })
    }


    /// Kind → everyday-cache category. nil = not remembered: tourist stops
    /// and the trucker-specific kinds aren't everyday habits near home.
    static func everydayCategory(for kind: Kind) -> EverydayCategory? {
        switch kind {
        case .gas: return .fuel
        case .food: return .food
        case .stores: return .stores
        case .rest: return .rest
        case .shelter: return .shelter
        case .medical: return .medical
        case .hotel: return .hotels
        case .gyms: return .gyms
        // Repeat-visit stop types ARE habits: a trucker returns to the same
        // shower and the same overnight parking, a commuter to the same
        // garage. Their taps used to be dropped on the floor.
        case .shower: return .showers
        case .truckParking, .parking: return .parking
        // Genuinely not habits, and deliberately still excluded: an
        // attraction is somewhere you go ONCE (frequency would rank the
        // place you've already seen above the one you haven't), and a weigh
        // station is a legal obligation, not a preference — "learning" it
        // would just re-suggest a mandatory stop as if it were a choice.
        case .tourist, .weighStation: return nil
        }
    }

    /// A ranked result row for the list card.
    struct RankedPOI: Identifiable {
        let id = UUID()
        let item: MKMapItem
        let aheadMeters: CLLocationDistance
        let detourMeters: CLLocationDistance
        /// Fuel $/unit or hotel $/night, when a source is available.
        let pricePerUnit: Double?
        /// Public review rating 0…5 (hotels/food), when a source is available.
        var rating: Double? = nil
        /// Cost tier 1–5 ("$"…"$$$$$", income-anchored), when known.
        var costTier: Int? = nil
        /// Trucker shower availability (brand table).
        var showers: ShowerAvailability = .unknown
        /// Open right now (Yelp hours, when a key is configured).
        var isOpenNow: Bool? = nil
        /// The provider's business page (Yelp requires the link).
        var businessURL: URL? = nil
        /// Parking only: true = costs money, false = free, nil = unknown.
        var parkingFee: Bool? = nil
        /// Shelter only: plain-words type ("Storm shelter", "Flood shelter",
        /// "Cooling center", "Emergency shelter").
        var shelterType: String? = nil
        /// True when pricePerUnit is a REAL posted price (CRE/TomTom), not
        /// a state-average estimate — the HUD only headlines real prices.
        var isLivePrice = false
        /// How far the row's distance can be trusted as a route fact.
        var placement: Placement = .onRoute
    }

    /// What a row's distance means. Only a ranked row knows how far AHEAD a
    /// stop is and what the detour costs; the others know a straight line.
    enum Placement {
        /// Ranked along the route: miles ahead, detour minutes.
        case onRoute
        /// Straight-line miles from the vehicle (the nearest ER, a
        /// remembered stop before the search confirms it).
        case straightLine
        /// Nothing ranked on the route; the nearest hits around it, shown
        /// so the driver isn't told none exist — but not on the route.
        case offRoute
    }

    @Published private(set) var results: [RankedPOI] = []
    @Published var activeKind: Kind?
    @Published private(set) var isSearching = false
    @Published private(set) var emptyResultMessage: String?
    /// Row the driver tapped — map zooms to it; Add Stop targets it.
    @Published var selected: RankedPOI?
    /// Tourist star the driver tapped — opens the stop's detail card
    /// (kept separate from `selected`, which auto-picks the first result
    /// after every search; the card must only appear on a real tap).
    @Published var touristDetail: RankedPOI?

    /// Food flow: category picker shown before searching.
    @Published var pendingFoodChoice = false
    @Published var activeFoodCategory: FoodCategory?

    /// Stores flow: category picker (Grocery/Electronics/…) before searching.
    @Published var pendingStoreChoice = false
    @Published var activeStoreCategory: StoreCategory?

    /// Gas flow: fuel type persisted after the first choice (Settings gear
    /// can change it later); nil = never chosen → prompt once.
    @Published var pendingFuelChoice = false
    @Published var fuelType: FuelType? {
        didSet {
            UserDefaults.standard.set(fuelType?.rawValue, forKey: Self.fuelTypeKey)
        }
    }

    /// Long-haul mode (Trucker route option): fuel searches favor truck
    /// stops (Loves / Pilot / Flying J / TA), the allowed detour range grows
    /// (savings justify distance on long hauls), and the fill size reflects
    /// a long-haul tank so price dominates the cost model.
    @Published var truckerMode = false

    /// Monotonic search id — see the generation guard in `search()`.
    private var searchGeneration = 0

    /// Where the driver was when the last search started — the everyday
    /// cache's lookup-context (start cell) for habit correlation.
    private var lastSearchPosition: CLLocationCoordinate2D?

    /// What counts as shelter from whatever is actually happening — set by
    /// AppModel from ShelterPolicy. Ordinary open buildings for weather you
    /// wait out indoors, real shelters only when the hazard needs one.
    var shelterQueries: () -> [String] = { ShelterPolicy.Kind.anyBuilding.searchQueries }

    /// Station-level price source — nil prices until a licensed feed
    /// (GasBuddy / OPIS) is wired in; the cost model then uses fleet averages
    /// for comparability and the UI shows "price unavailable".
    var priceProvider: (MKMapItem, FuelType) -> Double? = { _, _ in nil }
    /// Async LIVE station price (TomTom when keyed) — overrides the estimate.
    var livePriceProvider: (CLLocationCoordinate2D, FuelType) async -> Double? = { _, _ in nil }

    /// Hotel review/price source — publicly available ratings need a
    /// licensed places feed (Yelp Fusion / Google Places); until wired,
    /// hotel ranking degrades to closest-to-corridor (POIRanking.rankHotels
    /// treats unknowns as neutral).
    var hotelInfoProvider: (MKMapItem) -> (rating: Double?, nightly: Double?) = { _ in (nil, nil) }

    private static let fuelTypeKey = "flows.fuelType"

    private var routePath: POIRanking.RoutePath?
    private var corridor: [CLLocationCoordinate2D] = []
    /// Bundled per-location shower table (1,505 OSM truck stops).
    /// `static let` (lazy, once) — as stored `let`s these four decoded
    /// ~160 KB of JSON on the main thread during APP LAUNCH (POIService is an
    /// eager AppModel property); now they parse on the first shower lookup.
    private static let showerTable = ShowerAvailability.LocationTable.loadBundled()
    /// Verified city-keyed shower counts (scraped chain store pages).
    // VERIFIED per-city shower counts, one table per chain (scraped from each
    // brand's own store data) — kept separate so a Love's hit never matches a
    // Pilot city key. Pilot/Flying J + Love's + TA/Petro are all verified now.
    private static let cityShowers = ShowerAvailability.CityTable.loadBundled()
    private static let lovesShowers = ShowerAvailability.CityTable.loadBundled(
        resource: "loves_city_showers")
    private static let taShowers = ShowerAvailability.CityTable.loadBundled(
        resource: "ta_petro_city_showers")

    init() {
        fuelType = UserDefaults.standard.string(forKey: Self.fuelTypeKey)
            .flatMap(FuelType.init(rawValue:))
    }

    func beginCorridorSearch(along route: PlannedRoute) {
        let part = RouteService.corridorPartition(of: route.route.polyline, everyMeters: 30_000)
        corridor = part.samples
        // Full-resolution path for ahead/detour ranking (decimated to ~1500
        // points so nearest() stays sub-millisecond).
        let poly = route.route.polyline
        let n = poly.pointCount
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        let step = Int(flows_places_route_decimation_step(Int64(coords.count)))
        if step > 1 {
            coords = stride(from: 0, to: coords.count, by: step).map { coords[$0] }
        }
        routePath = POIRanking.RoutePath(coords: coords)
    }

    func reset() {
        corridor = []
        routePath = nil
        clearResults()
    }

    /// Entry point for the HUD buttons. Food and first-time Gas divert into
    /// their category pickers; everything else searches immediately.
    func request(_ kind: Kind, aheadOf position: CLLocationCoordinate2D?) async {
        // BUTTON ISOLATION: pressing any button clears every other kind's
        // submenu, category state, and title — nothing bleeds across.
        // Bump the generation FIRST: an in-flight search from the previous
        // tap must not repopulate results (and re-zoom the map) behind the
        // freshly opened category picker.
        searchGeneration += 1
        pendingFoodChoice = false
        pendingFuelChoice = false
        pendingStoreChoice = false
        activeFoodCategory = nil
        activeStoreCategory = nil
        results = []
        selected = nil
        touristDetail = nil
        emptyResultMessage = nil
        switch kind {
        case .food:
            activeKind = kind
            pendingFoodChoice = true
        case .stores:
            activeKind = kind
            pendingStoreChoice = true
        case .tourist:
            // Notable stops along the way: parks, monuments, museums —
            // Mammoth Cave shows up on the Louisville→Nashville corridor.
            await search(kind, queries: Self.touristQueries, aheadOf: position)
        case .gas:
            activeKind = kind
            if let fuel = fuelType {
                await search(kind, queries: fuelQueries(fuel), fuel: fuel, aheadOf: position)
            } else {
                pendingFuelChoice = true   // first run only; persisted after
            }
        case .rest:
            // State/county rest areas AND commercial stops: MKLocalSearch
            // names official areas "rest area" / "welcome center" / "service
            // plaza" depending on the state — search all three.
            // (Trucker parking/scales have their own buttons — mixing
            // "truck parking" here surfaced CAT Scales as rest areas.)
            await search(kind, queries: ["rest area", "welcome center", "service plaza"],
                         aheadOf: position)
        case .hotel:
            // Plain lodging queries — the category filter guarantees hotels;
            // truck-friendliness comes from ranking bias, not the query (the
            // old "motel truck parking" phrasing conflicted with the
            // hotel-only filter and returned NOTHING).
            await search(kind, queries: ["hotel", "motel"], aheadOf: position)
        case .medical:
            // Emergencies don't care about direction of travel: the list
            // leads with the ABSOLUTE nearest ER, wide radius.
            await search(kind, queries: ["emergency room hospital", "urgent care"],
                         aheadOf: position)
        case .shelter:
            // Government-recognized public refuge only: the alert-specific
            // Whatever the hazard actually calls for (ShelterPolicy), each
            // term its own search — MKLocalSearch matches a query as a
            // PHRASE, so a string of them finds nothing. Private noise
            // (animal shelters, service offices) is name-filtered after.
            await search(kind, queries: shelterQueries(), aheadOf: position)
        case .gyms:
            await search(kind, queries: ["gym", "fitness center"], aheadOf: position)
        case .shower:
            await search(kind, queries: ["truck stop", "travel center",
                                         "Love's Travel Stop", "Pilot Travel Center",
                                         "Flying J", "TA Travel Center", "Petro"],
                         aheadOf: position)
        case .truckParking:
            // Legal overnight parking: truck stops, official rest areas, and
            // the signed ramp/weigh-station lots states allow.
            await search(kind, queries: ["truck parking", "rest area truck parking"],
                         aheadOf: position)
        case .parking:
            await search(kind, queries: ["parking", "free parking"], aheadOf: position)
        case .weighStation:
            await search(kind, queries: ["weigh station", "truck scales CAT scale"],
                         aheadOf: position)
        }
    }

    /// The tourist button's queries — also the per-route count's.
    private static let touristQueries = ["national park monument",
                                         "tourist attraction landmark museum"]

    /// Attractions near ONE route's own road, for the tourist order on the
    /// choice cards: the tourist button's queries, box and spread of search
    /// points, run along that route WITHOUT touching the results card. The
    /// pins follow the highlighted route, and counting them handed the
    /// tapped card the most stops, so it jumped to the top of the list.
    func touristCount(along route: PlannedRoute) async -> Int {
        let samples = RouteService.corridorPartition(
            of: route.route.polyline, everyMeters: 30_000).samples
        let centerCap = Int(flows_places_search_center_cap(Int64(Self.touristQueries.count)))
        let centers = POIRanking.centerPicks(count: samples.count, cap: centerCap)
            .map { samples[$0] }
        let policy = Kind.tourist.policy
        var found: [MKMapItem] = []
        for center in centers {
            for query in Self.touristQueries {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.resultTypes = .pointOfInterest
                request.pointOfInterestFilter = Self.poiFilter(for: .tourist, fuel: nil)
                request.region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: policy.region_meters,
                    longitudinalMeters: policy.region_meters)
                found.append(contentsOf: await Self.pacedLocalSearch(request))
                if Task.isCancelled { return 0 }
            }
        }
        // The same offline supplement the button's sweep merges in.
        if let groups = Self.shardGroups(for: .tourist) {
            for center in centers {
                for p in await PlacesStore.shared.places(
                    near: center, groups: groups, radiusMeters: policy.region_meters) {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: p.coordinate))
                    item.name = p.name
                    found.append(item)
                }
            }
        }
        let places = dedupIndices(found, locationOnly: policy.location_dedup)
            .map { found[$0].placemark.coordinate }
        // Within a worthwhile detour (40 km) of the route.
        return places.filter { place in
            samples.contains { POIRanking.meters($0, place) < 40_000 }
        }.count
    }

    /// Siri's add-a-stop search: the same corridor sweep as the buttons,
    /// but for ONE named place or chain ("Starbucks", "Buc-ee's",
    /// "Yellowstone"), returning candidates nearest-first WITHOUT touching
    /// the results card — Siri adds the best match directly, so no
    /// published state may change under a live search.
    func namedStops(_ term: String,
                    aheadOf position: CLLocationCoordinate2D?) async -> [MKMapItem] {
        var centers: [CLLocationCoordinate2D] = position.map { [$0] } ?? []
        let ahead = corridorAhead(of: position)
        centers.append(contentsOf: POIRanking.centerPicks(count: ahead.count, cap: SearchLimits.namedCenters)
            .map { ahead[$0] })
        var found: [MKMapItem] = []
        for center in centers.prefix(SearchLimits.namedCenters) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = term
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: SearchLimits.namedRegionMeters,
                longitudinalMeters: SearchLimits.namedRegionMeters)
            found.append(contentsOf: await Self.pacedLocalSearch(request))
            if found.count >= SearchLimits.namedEnoughHits { break }
        }
        // Prefer places whose NAME carries the asked words — MKLocalSearch
        // fills sparse areas with same-category lookalikes (a Starbucks
        // query in ranch country returns any cafe). Lookalikes stay as the
        // fallback: Siri speaks the real name back, so nothing is added
        // silently under a wrong label.
        let named = found.filter { BrandKnowledge.askedName(term, matches: $0.name ?? "") }
        let candidates = named.isEmpty ? found : named
        let unique = dedupIndices(candidates, locationOnly: false).map { candidates[$0] }
        guard let from = position else { return unique }
        return POIRanking.byDistance(unique.map(\.placemark.coordinate), from: from, limit: unique.count)
            .map { unique[$0.index] }
    }

    /// Food category chosen from the picker.
    func chooseFood(_ category: FoodCategory, aheadOf position: CLLocationCoordinate2D?) async {
        pendingFoodChoice = false
        activeFoodCategory = category
        await search(.food, queries: [category.searchQuery], aheadOf: position)
    }

    /// Store category chosen from the picker.
    func chooseStore(_ category: StoreCategory, aheadOf position: CLLocationCoordinate2D?) async {
        pendingStoreChoice = false
        activeStoreCategory = category
        await search(.stores, queries: category.searchQueries, aheadOf: position)
    }

    /// Fuel type chosen (first run or from Settings).
    func chooseFuel(_ fuel: FuelType, aheadOf position: CLLocationCoordinate2D?) async {
        pendingFuelChoice = false
        fuelType = fuel
        await search(.gas, queries: fuelQueries(fuel), fuel: fuel, aheadOf: position)
    }

    /// One fuel-query builder (was copy-pasted in request() and chooseFuel()).
    /// In trucker mode, truck stops ride along as their OWN queries:
    /// MKLocalSearch matches a query as a phrase, and the old run-on
    /// "truck stop gas station Loves Pilot Flying J TA" matched nothing on
    /// the corridor — the list fell back to Love's stations 549 miles away.
    private func fuelQueries(_ fuel: FuelType) -> [String] {
        truckerMode && fuel != .electric
            ? [fuel.searchQuery, "truck stop", "travel center"]
            : [fuel.searchQuery]
    }

    /// One MKLocalSearch with the throttle handled: MapKit rejects rapid
    /// bursts (MKError.loadingThrottled) and the old bare `try?` swallowed
    /// that into "no results" — a 15-request sweep (5 centers x 3 queries)
    /// could come back completely empty and the card said "none found ahead"
    /// with pharmacies in plain sight. Retries once after the throttle
    /// window and paces successive calls.
    private static func pacedLocalSearch(_ request: MKLocalSearch.Request) async -> [MKMapItem] {
        for attempt in 0..<2 {
            do {
                let response = try await MKLocalSearch(request: request).start()
                // Small gap between burst requests keeps MapKit's limiter happy.
                try? await Task.sleep(for: .milliseconds(120))
                return response.mapItems
            } catch {
                let mk = (error as? MKError)?.code
                if attempt == 0, mk == .loadingThrottled {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                return []
            }
        }
        return []
    }

    private func search(
        _ kind: Kind, queries: [String], fuel: FuelType? = nil,
        aheadOf position: CLLocationCoordinate2D?
    ) async {
        activeKind = kind
        // Generation guard: a rapid same-kind re-tap starts a NEWER search;
        // the superseded one must neither clear the shared isSearching flag
        // mid-flight nor repopulate stale results behind a fresh picker.
        searchGeneration += 1
        let gen = searchGeneration
        isSearching = true
        emptyResultMessage = nil
        selected = nil
        touristDetail = nil
        defer { if gen == searchGeneration { isSearching = false } }

        // INSTANT-FIRST: inside the learned everyday circle, the stops the
        // driver already uses appear immediately (most-used first) while the
        // network searches run; the fresh results merge in below.
        lastSearchPosition = position
        let category = Self.everydayCategory(for: kind)
        // Truck parking shares the parking habit store with car parking: a
        // remembered campus garage must not be pinned into a trucker's list.
        let everyday: [RankedPOI] = category.map { cat in
            EverydayPlaces.shared.instantResults(in: cat, near: position)
                .filter { kind != .truckParking || Self.truckCanPark(named: $0.name) }
                .prefix(SearchLimits.instantRows).map { Self.instantRow(for: $0, from: position) }
        } ?? []
        if !everyday.isEmpty {
            results = everyday
            selected = everyday.first
        }

        var found: [MKMapItem] = []
        var centers: [CLLocationCoordinate2D] = position.map { [$0] } ?? []
        // Multi-query kinds probe fewer centers so total request count stays
        // level (3 centers x 3 queries ≈ 5 centers x 1 query + change).
        let centerCap = Int(flows_places_search_center_cap(Int64(queries.count)))
        // Spread centers EVENLY along the remaining corridor (a GA→WI route
        // used to search only near the start — hotels 800 mi ahead never
        // appeared).
        let ahead = corridorAhead(of: position)
        centers.append(contentsOf: POIRanking.centerPicks(count: ahead.count, cap: centerCap)
            .map { ahead[$0] })
        // What this kind does differently (rust/flows-core places.rs): hotels
        // and stores cluster in towns OFF the highway, parks sit well off the
        // interstate and ERs matter at any range, so each searches its own
        // box size; the same policy names the fallbacks and decorations below.
        let policy = kind.policy
        let regionMeters = policy.region_meters
        searchLoop: for center in centers.prefix(centerCap) {
            for query in queries {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.resultTypes = .pointOfInterest
                request.pointOfInterestFilter = Self.poiFilter(for: kind, fuel: fuel)
                request.region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: regionMeters, longitudinalMeters: regionMeters)
                found.append(contentsOf: await Self.pacedLocalSearch(request))
                // Multi-center x multi-query can reach 15 requests; enough
                // raw hits means later centers only add far-away duplicates.
                if found.count >= SearchLimits.enoughHits { break searchLoop }
                if gen != searchGeneration { return }   // superseded mid-sweep
            }
        }
        // OFFLINE-FIRST supplement: FLOWS's own FSQ OS Places shards (7.5M US
        // POIs, Apache 2.0, keyless). Results merge with MKLocalSearch's and
        // dedup below removes overlap — with no network, this is the whole
        // list; with network, it fills the chains MKLocalSearch misses.
        if let groups = Self.shardGroups(for: kind) {
            for center in centers.prefix(centerCap) {
                for p in await PlacesStore.shared.places(
                    near: center, groups: groups, radiusMeters: regionMeters) {
                    let placemark = MKPlacemark(
                        coordinate: p.coordinate,
                        addressDictionary: [
                            "Street": p.street, "City": p.city,
                        ])
                    let item = MKMapItem(placemark: placemark)
                    item.name = p.name
                    if !p.website.isEmpty { item.url = URL(string: p.website) }
                    found.append(item)
                }
            }
        }

        // Dedup by name+proximity. Weigh stations dedup by LOCATION alone
        // (~1 km): the same CAT Scale arrives from both queries under name
        // variants ("CAT Scale" / "CAT Scale Company") and showed as
        // duplicate rows.
        var unique = dedupIndices(found, locationOnly: policy.location_dedup).map { found[$0] }
        // Public shelters only: the shelter queries also surface animal/pet
        // shelters and service offices no storm-warned driver can use.
        if kind == .shelter {
            unique = unique.filter { !BrandKnowledge.isShelterNoise(name: $0.name ?? "") }
        }
        // Truck parking: a "truck parking" search also finds every car park
        // and campus garage nearby — low-clearance ramps no truck fits.
        if kind == .truckParking {
            unique = unique.filter { Self.truckCanPark(named: $0.name ?? "") }
        }

        // Prices/ratings come from main-actor state; the O(items × vertices)
        // ranking hops off the main actor (review finding: it ran during
        // navigation renders and stalled frames on long routes).
        var prices: [Double?]
        var ratings: [Double?]
        var costTiers: [Int?] = unique.map { _ in nil }
        var liveIDs = Set<ObjectIdentifier>()
        var openFlags: [Bool?] = unique.map { _ in nil }
        var businessURLs: [URL?] = unique.map { _ in nil }
        if policy.ratings_lookup {
            // Public reviews + cost: Yelp Fusion when a key is configured
            // (Settings → Data sources); stars/$ hide otherwise. Gyms and
            // shelters ride along for the open-now hours the same lookup
            // carries.
            var r: [Double?] = []
            var t: [Int?] = []
            var open: [Bool?] = []
            var urls: [URL?] = []
            for item in unique {
                let c = item.placemark.coordinate
                // Provider ladder: Google Places (bigger free quota) → Yelp.
                if let info = await RatingsProvider.info(
                    name: item.name ?? "", latitude: c.latitude, longitude: c.longitude) {
                    r.append(info.rating)
                    t.append(info.price.map {
                        RatingsAndCost.costTier(yelpPrice: $0, rating: info.rating)
                    })
                    open.append(info.isOpenNow)
                    urls.append(info.url)
                } else {
                    r.append(nil)
                    t.append(nil)
                    open.append(nil)
                    urls.append(nil)
                }
            }
            ratings = r
            costTiers = t
            openFlags = open
            businessURLs = urls
            prices = kind == .hotel
                ? unique.map { self.hotelInfoProvider($0).nightly }
                : unique.map { _ in nil }
        } else {
            var p: [Double?] = []
            // Never a blank price column: before the driver has picked a
            // fuel type, gas rows price as regular gasoline (the estimate is
            // already labeled "est." in the UI); the pick refines, it does
            // not reveal.
            let pricingFuel = fuel ?? (kind == .gas ? .gas : nil)
            for item in unique {
                var value = pricingFuel.flatMap { self.priceProvider(item, $0) }
                if let fuel, let live = await self.livePriceProvider(
                    item.placemark.coordinate, fuel) {
                    value = live   // real station price wins over the estimate
                    liveIDs.insert(ObjectIdentifier(item))
                }
                p.append(value)
            }
            prices = p
            ratings = unique.map { _ in nil }
        }
        var ranked = await Self.rank(
            unique, kind: kind, prices: prices, ratings: ratings, fuel: fuel,
            position: position, path: routePath, trucker: truckerMode)
        // Attach cost tiers + shower availability (brand table: Love's /
        // Pilot / TA showers are brand standard unless disproven).
        let tierByName = Dictionary(uniqueKeysWithValues:
            zip(unique.map { ObjectIdentifier($0) }, costTiers))
        let openByName = Dictionary(uniqueKeysWithValues:
            zip(unique.map { ObjectIdentifier($0) }, openFlags))
        let urlByName = Dictionary(uniqueKeysWithValues:
            zip(unique.map { ObjectIdentifier($0) }, businessURLs))
        ranked = ranked.map { row in
            var r = row
            r.costTier = tierByName[ObjectIdentifier(row.item)] ?? nil
            r.isOpenNow = openByName[ObjectIdentifier(row.item)] ?? nil
            r.businessURL = urlByName[ObjectIdentifier(row.item)] ?? nil
            r.isLivePrice = liveIDs.contains(ObjectIdentifier(row.item))
            let poiName = row.item.name ?? ""
            // Brand-table prefill: with no ratings key (or no provider
            // listing), national chains still get their known "$" tier.
            if r.costTier == nil, policy.brand_cost_tier {
                r.costTier = BrandKnowledge.costTier(name: poiName)
            }
            // Hotel rows get the chain's own site when MapKit gave none.
            if kind == .hotel, row.item.url == nil {
                row.item.url = BrandKnowledge.website(name: poiName)
            }
            if kind == .parking {
                r.parkingFee = BrandKnowledge.parkingFee(name: poiName)
            }
            if kind == .shelter {
                // Only the FIRST query carries the live warning's intent
                // (shelterQuery() picks it per event); the static probe
                // queries contain the word "storm" and mislabeled every
                // unnamed shelter during floods and heat events.
                r.shelterType = BrandKnowledge.shelterType(
                    name: poiName, query: queries.first ?? "")
            }
            // Gym showers are a brand standard (or a known brand omission);
            // unknown brands say nothing rather than guess.
            if kind == .gyms, let has = BrandKnowledge.gymHasShowers(name: poiName) {
                r.showers = has ? .standard : .none
            }
            if policy.shower_ladder {
                let c = row.item.placemark.coordinate
                // VERIFIED chain data first (each brand's own store data,
                // keyed by the placemark's state+city), then the ladder.
                // Brand-anchored matches on the lowercased name (places.rs
                // `shower_brand`): bare substrings ("ta ", "love") had
                // false-positived on ordinary names like Loveland.
                let brandTable: ShowerAvailability.CityTable? =
                    switch flows_places_shower_brand(row.item.name ?? "") {
                    case 1: Self.cityShowers
                    case 2: Self.lovesShowers
                    case 3: Self.taShowers
                    default: nil
                    }
                // DRIVER REPORT OUTRANKS EVERYTHING — including the verified
                // brand table. The ladder is documented as "driver report →
                // table tag → brand", but the brand-city branch below
                // short-circuited before the report was ever consulted, so a
                // trucker reporting "no showers" at a Pilot was silently
                // overruled by the chain's own data. Someone standing in the
                // building beats a spreadsheet about it.
                if ShowerAvailability.isDisproved(lat: c.latitude, lon: c.longitude) {
                    r.showers = .disproven
                } else if let table = brandTable,
                          let count = table.showers(
                            state: row.item.placemark.administrativeArea,
                            city: row.item.placemark.locality) {
                    r.showers = count > 0 ? .standard : .none
                } else {
                    r.showers = ShowerAvailability.forStop(
                        named: row.item.name, lat: c.latitude, lon: c.longitude,
                        table: Self.showerTable)
                }
            }
            return r
        }
        guard gen == searchGeneration, activeKind == kind else { return }   // superseded
        // Never offer a stop that's outside its operating hours (unknown
        // hours stay listed).
        var finalRanked = ranked.filter { $0.isOpenNow != false }
        // ...but for ESSENTIAL categories, never tell a driver "none found" when
        // stations exist and were only filtered out as closed — Yelp hours are
        // frequently stale/wrong, and stranding someone low on fuel at 2am on bad
        // hours data is worse than showing a maybe-closed option. Fall back to the
        // full ranked list (closest first) instead of an empty result.
        if finalRanked.isEmpty, !ranked.isEmpty, policy.closed_fallback {
            finalRanked = ranked
        }
        // If the ahead-only/detour ranking dropped EVERY raw hit (vehicle
        // position quirks, all hits slightly behind, tight detour caps),
        // showing the nearest raw results beats claiming nothing exists.
        // Only hits inside the boxes this sweep searched: MapKit treats the
        // region as a hint and answers a brand query from anywhere, and the
        // fallback once listed Love's stations 549 miles off an 80-mile trip.
        // They're labelled as off the route, never as miles ahead.
        if finalRanked.isEmpty, !unique.isEmpty, let anchor = position ?? centers.first,
           policy.empty_fallback {
            let searched = Array(centers.prefix(centerCap))
            let nearby = unique.filter { item in
                searched.contains {
                    POIRanking.meters($0, item.placemark.coordinate) <= regionMeters
                }
            }
            finalRanked = POIRanking.byDistance(nearby.map(\.placemark.coordinate), from: anchor,
                                                limit: SearchLimits.fallbackRows)
                .map { RankedPOI(item: nearby[$0.index], aheadMeters: $0.meters,
                                 detourMeters: 0, pricePerUnit: nil, placement: .offRoute) }
        }
        // Medical rule: the ABSOLUTE nearest hospital/ER leads, regardless
        // of route direction — straight-line from the vehicle.
        if policy.nearest_leads, let position {
            if let i = POIRanking.firstNearest(unique.map(\.placemark.coordinate), to: position) {
                let nearest = unique[i]
                let d = POIRanking.meters(nearest.placemark.coordinate, position)
                let top = RankedPOI(item: nearest, aheadMeters: d, detourMeters: 0,
                                    pricePerUnit: nil, placement: .straightLine)
                finalRanked = [top] + finalRanked.filter { $0.item !== nearest }
            }
        }
        // Remember what this search found inside the everyday circle (the
        // store ignores everything outside it), then merge: remembered stops
        // stay pinned first, most-used first — except Medical, where the
        // nearest ER must lead and habit never outranks an emergency.
        if let category {
            EverydayPlaces.shared.remember(
                unique.map {
                    let c = $0.placemark.coordinate
                    return (name: $0.name ?? "?", lat: c.latitude, lon: c.longitude,
                            street: $0.placemark.thoroughfare ?? "",
                            city: $0.placemark.locality ?? "")
                },
                in: category)
        }
        // ...and a remembered stop the fresh search says is CLOSED right now
        // loses its pin (it can still rank normally via the essential-kind
        // fallback above, flagged as maybe-closed).
        let closedKeys = ranked.filter { $0.isOpenNow == false }.map(Self.rowKey)
        // Once ranked results exist, a remembered stop keeps its top pin ONLY
        // when the corridor search confirmed it (real ahead/detour numbers).
        // Unconfirmed remembered stops drop off rather than sit above the
        // ranking with straight-line distances — on a long trip away from
        // home they could be hundreds of miles BEHIND the vehicle.
        let pinned = Self.pinned(policy.habit_pins ? everyday : [], closedKeys: closedKeys,
                                 rankedKeys: finalRanked.map(Self.rowKey))
        results = Self.merged(everyday: pinned, network: finalRanked)
        // 16: don't yank the camera a second time — keep the driver's current
        // selection when it survived the merge; only reseat when it vanished.
        if let cur = selected, results.contains(where: { $0.id == cur.id }) == false {
            selected = results.first
        } else if selected == nil {
            selected = results.first
        }
        if results.isEmpty {
            emptyResultMessage = "No \(kind.rawValue.lowercased()) found ahead on this route."
            activeKind = nil
        }
    }

    /// A list row for a remembered everyday stop — straight-line distance
    /// until the ranked network row (with real ahead/detour) replaces it.
    private static func instantRow(for place: EverydayPlace,
                                   from position: CLLocationCoordinate2D?) -> RankedPOI {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude,
                                                longitude: place.longitude)
        let placemark = MKPlacemark(
            coordinate: coordinate,
            addressDictionary: ["Street": place.street, "City": place.city])
        let item = MKMapItem(placemark: placemark)
        item.name = place.name
        let ahead = position.map { POIRanking.meters(coordinate, $0) } ?? 0
        return RankedPOI(item: item, aheadMeters: ahead, detourMeters: 0,
                         pricePerUnit: nil, placement: .straightLine)
    }

    /// The everyday cache's stable identity for a result row (name + ~220 m
    /// cell) — the same attribute id the store keys entries by.
    private static func rowKey(_ row: RankedPOI) -> String {
        let c = row.item.placemark.coordinate
        return EverydayPlace.attributeID(name: row.item.name ?? "?",
                                         latitude: c.latitude, longitude: c.longitude)
    }

    /// Everyday-first merge: remembered stops lead in most-used order, but
    /// each takes the RICHER network row (price/rating/hours) when the fresh
    /// search found the same place; new finds follow in ranked order.
    private static func merged(everyday: [RankedPOI],
                               network: [RankedPOI]) -> [RankedPOI] {
        guard !everyday.isEmpty else { return network }
        let keys = RustTextColumn(everyday.map(rowKey) + network.map(rowKey))
        let pairs = keys.with { joined, lens, _ in
            flows_places_merge(joined, lens, Int64(everyday.count), Int64(network.count))
        }
        return stride(from: 0, to: pairs.count, by: 2).map {
            pairs[$0] == 0 ? everyday[Int(pairs[$0 + 1])] : network[Int(pairs[$0 + 1])]
        }
    }

    /// The remembered rows that keep their top pin: none a closed row names
    /// and, once ranked rows exist, only those the corridor search confirmed
    /// (keys compare as strings do; places.rs `pinned_rows`).
    private static func pinned(_ everyday: [RankedPOI], closedKeys: [String],
                               rankedKeys: [String]) -> [RankedPOI] {
        guard !everyday.isEmpty else { return [] }
        let keys = RustTextColumn(everyday.map(rowKey) + closedKeys + rankedKeys)
        return keys.with { joined, lens, _ in
            flows_places_pinned(joined, lens, Int64(everyday.count),
                                Int64(closedKeys.count), Int64(rankedKeys.count))
        }.map { everyday[Int($0)] }
    }

    /// Row tap: select the stop on the map AND count the lookup — the
    /// everyday cache ranks by how often each stop is actually used, and the
    /// context (time of day, weekday, start cell) feeds the habit patterns.
    /// Re-apply driver shower reports to the rows on screen, so tapping
    /// "no showers?" updates the list immediately instead of waiting for the
    /// next search.
    func refreshShowerResolution() {
        results = results.map { row in
            var r = row
            let c = row.item.placemark.coordinate
            if ShowerAvailability.isDisproved(lat: c.latitude, lon: c.longitude) {
                r.showers = .disproven
            }
            return r
        }
    }

    func choose(_ ranked: RankedPOI) {
        selected = ranked
        // The CHOICE SET, not just the winner: the rows that were on screen
        // and lost are what make a ranking weight identifiable at all. See
        // ChoiceLog — recorded passively, read by nothing yet.
        if let kind = activeKind {
            ChoiceLogStore.shared.record(
                kind: kind.rawValue,
                options: results.prefix(ChoiceLog.optionsPerEvent).enumerated().map { i, row in
                    ChoiceLog.Option(
                        aheadMiles: row.aheadMeters / 1609.344,
                        detourMiles: row.detourMeters / 1609.344,
                        price: row.pricePerUnit,
                        rating: row.rating,
                        costTier: row.costTier,
                        shownRank: i,
                        chosen: row.id == ranked.id)
                })
        }
        guard let kind = activeKind,
              let category = Self.everydayCategory(for: kind) else { return }
        let c = ranked.item.placemark.coordinate
        EverydayPlaces.shared.noteUse(name: ranked.item.name ?? "?",
                                      lat: c.latitude, lon: c.longitude,
                                      in: category, from: lastSearchPosition)
    }

    /// Route-aware ranking: ahead-only, capped detour, ordered per kind.
    /// nonisolated + async → runs on the global concurrent executor, off the
    /// main actor.
    private nonisolated static func rank(
        _ items: [MKMapItem], kind: Kind, prices: [Double?], ratings: [Double?],
        fuel: FuelType?, position: CLLocationCoordinate2D?,
        path: POIRanking.RoutePath?, trucker: Bool
    ) async -> [RankedPOI] {
        guard let path else {
            // No active route (shouldn't happen in nav): fall back to
            // straight-line distance from the vehicle.
            guard let position else { return [] }
            return POIRanking.byDistance(items.map(\.placemark.coordinate), from: position,
                                         limit: SearchLimits.rankedRows)
                .map { RankedPOI(item: items[$0.index], aheadMeters: $0.meters, detourMeters: 0,
                                 pricePerUnit: nil, placement: .straightLine) }
        }
        // Each item pairs with its price and rating; a shorter list drops the
        // items past its end, as zipping them always did.
        let n = min(items.count, prices.count, ratings.count)
        guard n > 0 else { return [] }
        let coords = items.prefix(n).map(\.placemark.coordinate)
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let priceValues = prices.prefix(n).map { $0 ?? 0 }
        let hasPrice = prices.prefix(n).map { UInt8($0 == nil ? 0 : 1) }
        let ratingValues = ratings.prefix(n).map { $0 ?? 0 }
        let hasRating = ratings.prefix(n).map { UInt8($0 == nil ? 0 : 1) }
        let names = RustTextColumn(items.prefix(n).map(\.name))
        // The vehicle's place along the route, every item's route metrics,
        // the kind's detour cap (hotels, stores, ERs and tourist stops justify
        // longer detours; trucker mode widens them), the kind's ordering —
        // parking by cost tier, stores by rating then brand, hotels by value,
        // a chosen fuel by fill cost plus detour time with a long-haul tank,
        // everything else soonest first — and the row cap: rust/flows-core
        // places.rs `rank_along`, as [item, ahead, detour] triples.
        let rows = names.with { joined, lens, present in
            lats.withUnsafeBufferPointer { la in
                lons.withUnsafeBufferPointer { lo in
                    priceValues.withUnsafeBufferPointer { p in
                        hasPrice.withUnsafeBufferPointer { hp in
                            ratingValues.withUnsafeBufferPointer { r in
                                hasRating.withUnsafeBufferPointer { hr in
                                    path.handle.rank_along(
                                        kind.rustCode, fuel != nil, fuel?.rustCode ?? 0, trucker,
                                        position != nil, position?.latitude ?? 0, position?.longitude ?? 0,
                                        la, lo, p, hp, r, hr, joined, lens, present)
                                }
                            }
                        }
                    }
                }
            }
        }
        return stride(from: 0, to: rows.count, by: 3).map { k in
            let i = Int(rows[k])
            return RankedPOI(item: items[i], aheadMeters: rows[k + 1], detourMeters: rows[k + 2],
                             pricePerUnit: prices[i], rating: ratings[i])
        }
    }

    /// Somewhere a truck can park: a truck stop, rest area, travel plaza or
    /// the like, never a car park (rust/flows-core places.rs
    /// `truck_parking_admissible`).
    nonisolated static func truckCanPark(named name: String) -> Bool {
        !name.isEmpty && flows_places_truck_parking_admissible(name)
    }

    func clearResults() {
        searchGeneration += 1   // invalidate any in-flight search
        results = []
        activeKind = nil
        activeFoodCategory = nil
        activeStoreCategory = nil
        selected = nil
        touristDetail = nil
        emptyResultMessage = nil
        pendingFoodChoice = false
        pendingFuelChoice = false
        pendingStoreChoice = false
    }

    private func corridorAhead(of position: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D] {
        guard let position,
              let nearestIdx = POIRanking.firstNearest(corridor, to: position)
        else { return corridor }
        return Array(corridor[nearestIdx...])
    }
}

extension POIService.Kind {
    /// The kind's position in `allCases` — its declaration order, the code
    /// rust/flows-core places.rs numbers kinds by.
    var rustCode: UInt8 { UInt8(Self.allCases.firstIndex(of: self) ?? 0) }

    /// What the stop search does differently for this kind (places.rs
    /// `kind_policy`): detour caps, box size, shard groups, and which
    /// fallbacks and row decorations apply.
    var policy: FlowsPlacesKindPolicy { flows_places_kind_policy(rustCode) }
}

/// The stop search's row and hit limits, spelled once in places.rs.
private enum SearchLimits {
    static let rankedRows = Int(flows_places_limits().ranked_rows)
    static let instantRows = Int(flows_places_limits().instant_rows)
    static let fallbackRows = Int(flows_places_limits().fallback_rows)
    static let enoughHits = Int(flows_places_limits().search_enough_hits)
    static let namedEnoughHits = Int(flows_places_limits().named_enough_hits)
    static let namedCenters = Int(flows_places_limits().named_centers)
    static let namedRegionMeters = flows_places_limits().named_region_meters
}

/// The hits that survive the result dedup, in order: the first of each name
/// and ~220 m cell, or of each ~1 km cell alone for weigh stations, which
/// arrive under name variants (places.rs `dedup_rows`).
private func dedupIndices(_ items: [MKMapItem], locationOnly: Bool) -> [Int] {
    guard !items.isEmpty else { return [] }
    let names = RustTextColumn(items.map(\.name))
    let coords = items.map(\.placemark.coordinate)
    let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
    return names.with { joined, lens, present in
        lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                flows_places_dedup(locationOnly, joined, lens, present, la, lo)
            }
        }
    }.map { Int($0) }
}

/// Which POI button a scheduled trip need presses (kept out of
/// TripNeeds.swift so the trip-needs engine compiles headless for tests).
extension TripNeeds.Need {
    var poiKind: POIService.Kind {
        switch self {
        case .fuel: return .gas
        case .food: return .food
        case .rest: return .rest
        }
    }
}
