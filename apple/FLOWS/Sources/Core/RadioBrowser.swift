// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// AM/FM station search over the radio-browser.info COMMUNITY directory
/// (open, keyless — the same "primary/open source first" doctrine as the
/// hazard feeds; see docs/DATA_FEEDS.md).
///
/// Mirror etiquette per the project's API docs: the mirror list is fetched at
/// runtime from the all-servers name (`all.api.radio-browser.info`), one
/// healthy mirror is picked per launch (shuffled, so load spreads across
/// mirrors), and the all-servers name itself — which round-robins across the
/// same mirrors in DNS — is the fallback when the list can't be read.
///
/// Results are US stations only (`countrycode=US`, so the no-RU/CN/IR/NK
/// service rule holds structurally) and HTTPS streams only — ATS blocks
/// cleartext audio, and a directory this size always carries both schemes.
/// Playback rides the existing TruckerRadio AVPlayer path, including its
/// plain-words "Station is offline right now." failure text.
@MainActor
final class RadioBrowser: ObservableObject {
    struct Station: Identifiable, Equatable {
        let name: String
        /// HTTPS stream URL (the directory's resolved playback URL).
        let url: String
        /// First few genre words from the station's tags, for the row detail.
        let genre: String
        /// Community votes — the ranking the directory maintains.
        let votes: Int
        /// Transmitter position, when the directory lists one — what makes
        /// "local radio" mean the broadcaster down the road.
        var latitude: Double?
        var longitude: Double?

        var id: String { url }

        /// The dial position hiding in the station's name ("105.7 FM"), or
        /// nil when the name carries no frequency. It is what makes this
        /// read like a radio rather than a playlist.
        var dialLabel: String? { BroadcastRadio.dialLabel(from: name) }

        /// Bridge into the trucker-radio player (one shared AVPlayer path —
        /// tuning an AM/FM stream stops a NOAA relay and vice versa).
        var channel: TruckerRadio.Channel {
            TruckerRadio.Channel(name: name,
                                 detail: genre.isEmpty ? "AM/FM stream" : genre,
                                 url: url)
        }
    }

    @Published private(set) var stations: [Station] = []
    /// Plain-words progress/failure line under the search field.
    @Published private(set) var status: String?

    /// The mirror picked for this launch (nil until first use).
    private var host: String?

    static let allServersURL = "https://all.api.radio-browser.info/json/servers"

    /// How far out a "nearby" search reaches: about the span of a day's
    /// driving. Far enough that the dial doesn't empty out in open country,
    /// near enough that everything on it is plausibly a station you could
    /// have heard on the way.
    nonisolated static let nearbyRadiusMeters = Int(flows_tags_nearby_radius_meters())

    /// Stations around the vehicle, nearest first.
    ///
    /// The search is by DISTANCE, not by state, because a state query stops
    /// at the line — which is exactly wrong for a driver. Half of Madison's
    /// real dial broadcasts from Illinois, and someone crossing into Iowa
    /// should not watch their stations vanish at the river. Distance also
    /// means every result carries a position, so nearest-first is exact
    /// rather than a guess. The state list stays as the fallback for when
    /// there is no fix, or the geo index has nothing here.
    func searchNearby(near position: CLLocationCoordinate2D?,
                      stateCode: String?) async {
        status = "Finding stations…"
        guard let host = await ensureHost() else {
            status = "Station list didn't load. Check the connection and try again."
            return
        }
        if let position,
           let found = await fetchStations(
               Self.searchURL(host: host, state: nil, name: nil,
                              near: position)), !found.isEmpty {
            stations = Self.rankedNearest(found, near: position)
            status = nil
            return
        }
        await run(state: stateCode.flatMap { Self.stateName($0) }, name: nil)
    }

    /// Stations of one KIND, nearest first.
    ///
    /// The directory's own tag search is too loose to trust on its own: a
    /// "christian rock" station answers a tag search for `rock`, and a
    /// "sports talk" station answers one for `talk`. Every row that comes
    /// back is re-filed through BroadcastRadio.kind, whose match order puts
    /// the narrow kinds first, and anything that lands somewhere else is
    /// dropped. Asking for Rock gets rock.
    func searchGenre(_ kind: BroadcastRadio.Kind,
                     near position: CLLocationCoordinate2D?) async {
        status = "Finding stations…"
        guard let host = await ensureHost() else {
            status = "Station list didn't load. Check the connection and try again."
            return
        }
        var found: [Station] = []
        for word in kind.tagWords.prefix(3) {
            guard let batch = await fetchStations(
                Self.searchURL(host: host, state: nil, name: nil,
                               tag: word, near: position)) else { continue }
            found += batch
        }
        var seen = Set<String>()
        let filed = found.filter {
            BroadcastRadio.kind(forTags: $0.genre) == kind && seen.insert($0.id).inserted
        }
        stations = position.map { Self.rankedNearest(filed, near: $0) } ?? filed
        status = stations.isEmpty
            ? "No \(kind.title.lowercased()) stations near you right now." : nil
    }

    /// Nearest transmitter first; the directory's vote order decides between
    /// stations it can't place. "Local radio" means the broadcaster down the
    /// road, not the most-voted stream three states away.
    nonisolated static func rankedNearest(_ found: [Station],
                                          near position: CLLocationCoordinate2D)
        -> [Station] {
        // Each ranked station is the FIRST one sharing its stream URL, as the
        // directory lists a station once per bitrate (rust/flows-core
        // tags_and_replies.rs).
        let placeholder = found.isEmpty
        let lats = placeholder ? [0] : found.map { $0.latitude ?? 0 }
        let hasLat: [UInt8] = placeholder ? [0] : found.map { $0.latitude == nil ? 0 : 1 }
        let lons = placeholder ? [0] : found.map { $0.longitude ?? 0 }
        let hasLon: [UInt8] = placeholder ? [0] : found.map { $0.longitude == nil ? 0 : 1 }
        let votes = placeholder ? [0] : found.map { Int64($0.votes) }
        let order = RustTextColumn(found.map(\.url)).with { urls, urlLengths, _ in
            lats.withUnsafeBufferPointer { la in
                hasLat.withUnsafeBufferPointer { hla in
                    lons.withUnsafeBufferPointer { lo in
                        hasLon.withUnsafeBufferPointer { hlo in
                            votes.withUnsafeBufferPointer { vo in
                                Array(flows_tags_ranked_nearest(
                                    la, hla, lo, hlo, vo, urls, urlLengths, Int64(found.count),
                                    position.latitude, position.longitude))
                            }
                        }
                    }
                }
            }
        }
        return order.map { found[Int($0)] }
    }

    /// Free-text search across all US stations. The field promises "name
    /// or genre", so BOTH are queried — the directory's name search never
    /// matches tags ("bluegrass" would find only stations NAMED bluegrass)
    /// — and the merged list keeps name hits first.
    func search(text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        status = "Finding stations…"
        guard let host = await ensureHost() else {
            status = "Station list didn't load. Check the connection and try again."
            return
        }
        let byName = await fetchStations(
            Self.searchURL(host: host, state: nil, name: query))
        let byGenre = await fetchStations(
            Self.searchURL(host: host, state: nil, name: nil,
                           tag: query.lowercased()))
        guard let merged = Self.merged(nameHits: byName, tagHits: byGenre) else {
            status = "Station list didn't load. Check the connection and try again."
            return
        }
        stations = merged
        status = stations.isEmpty ? "No stations found. Try another word." : nil
    }

    private func run(state: String?, name: String?) async {
        status = "Finding stations…"
        guard let host = await ensureHost(),
              let found = await fetchStations(
                Self.searchURL(host: host, state: state, name: name)) else {
            status = "Station list didn't load. Check the connection and try again."
            return
        }
        stations = found
        status = stations.isEmpty ? "No stations found. Try another word." : nil
    }

    /// One search request → parsed stations; nil = the request itself
    /// failed (distinct from a clean empty result).
    private func fetchStations(_ url: URL?) async -> [Station]? {
        guard let url,
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.parseStations(data)
    }

    /// Pick one healthy mirror per launch: all-servers list → shuffle →
    /// first mirror whose stats endpoint answers OK. The all-servers name
    /// (DNS round-robin over the same mirrors) is the fallback.
    private func ensureHost() async -> String? {
        if let host { return host }
        if let listURL = URL(string: Self.allServersURL),
           let (data, resp) = try? await ThrottledNet.fetch(listURL),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            for candidate in Self.parseServers(data).shuffled()
            where Self.isAllowedMirror(candidate) {
                guard let stats = URL(string: "https://\(candidate)/json/stats"),
                      let (d, r) = try? await ThrottledNet.fetch(stats),
                      (r as? HTTPURLResponse)?.statusCode == 200,
                      Self.serverLooksHealthy(d) else { continue }
                host = candidate
                return candidate
            }
        }
        host = "all.api.radio-browser.info"
        return host
    }

    // MARK: - Pure logic (pinned by FLOWSTests)

    /// All-servers payload `[{"ip":…,"name":…}]` → unique host names in
    /// order (the list repeats a name once per IP family).
    /// Mirrors the app will talk to. The directory is community-run and
    /// any volunteer can register a mirror, so the runtime list is not a
    /// list FLOWS controls. Standing rule: no service operated from Russia,
    /// China, Iran or North Korea — and rather than blocklist those, only
    /// the known European/North American mirrors are allowed at all. A new
    /// mirror is admitted here on purpose, not by DNS.
    nonisolated static let allowedMirrorCountries: Set<String> = Set(RustWordList.words(4))

    /// `de1.api.radio-browser.info` → allowed; anything else → not.
    nonisolated static func isAllowedMirror(_ host: String) -> Bool {
        flows_tags_is_allowed_mirror(host)
    }

    nonisolated static func parseServers(_ data: Data) -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else { return [] }
        let names = rows.map { $0["name"] as? String }
        let kept = RustTextColumn(names).with { joined, lengths, present in
            Array(flows_tags_unique_server_names(joined, lengths, present, Int64(names.count)))
        }
        return kept.compactMap { names[Int($0)] }
    }

    /// Mirror stats payload → is this mirror serving? (`{"status":"OK"}`).
    nonisolated static func serverLooksHealthy(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return false }
        return json["status"] as? String == "OK"
    }

    /// Station search on a mirror: US only, working streams only
    /// (`hidebroken`), HTTPS only (`is_https` — re-checked client-side),
    /// community-vote order. `state`, `name`, and `tag` (genre) are the
    /// three search modes.
    nonisolated static func searchURL(host: String, state: String?,
                                      name: String?, tag: String? = nil,
                                      near: CLLocationCoordinate2D? = nil) -> URL? {
        // .urlQueryAllowed leaves & = + literal (the Yelp lesson) — use a
        // strict component set for the free-text term.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        var query = "countrycode=US&hidebroken=true&is_https=true"
            + "&order=votes&reverse=true&limit=60"
        if let state, let s = state.addingPercentEncoding(withAllowedCharacters: allowed) {
            query += "&state=\(s)"
        }
        if let name, let n = name.addingPercentEncoding(withAllowedCharacters: allowed) {
            query += "&name=\(n)"
        }
        if let tag, let t = tag.addingPercentEncoding(withAllowedCharacters: allowed) {
            query += "&tag=\(t)"
        }
        if let near {
            // A tenth of a degree (~11 km) is all a 400 km radius search
            // needs. The exact fix was being sent to a community-run
            // directory on every genre change — a stranger's server does
            // not need to know which driveway the car is in to answer
            // "what's on the air around here".
            let lat = (near.latitude * 10).rounded() / 10
            let lon = (near.longitude * 10).rounded() / 10
            query += "&geo_lat=\(lat)&geo_long=\(lon)"
                + "&geo_distance=\(nearbyRadiusMeters)"
        }
        return URL(string: "https://\(host)/json/stations/search?\(query)")
    }

    /// Merge the two free-text modes: name matches lead, genre (tag)
    /// matches follow, duplicates drop. nil only when BOTH requests failed
    /// — one working mode still serves.
    nonisolated static func merged(nameHits: [Station]?,
                                   tagHits: [Station]?) -> [Station]? {
        let combined = (nameHits ?? []) + (tagHits ?? [])
        let plan = RustTextColumn(combined.map(\.name)).with { names, nameLengths, _ in
            RustTextColumn(combined.map(\.url)).with { urls, urlLengths, _ in
                Array(flows_tags_merged_stations(
                    names, nameLengths, urls, urlLengths,
                    Int64(nameHits?.count ?? 0), nameHits != nil,
                    Int64(tagHits?.count ?? 0), tagHits != nil))
            }
        }
        guard plan.first == 1 else { return nil }
        return plan.dropFirst().map { combined[Int($0)] }
    }

    /// Station rows → playable list: HTTPS streams only (belt and braces —
    /// the server already filtered), de-duplicated by stream URL and by
    /// name (the directory lists one station once per bitrate), directory
    /// vote order preserved.
    nonisolated static func parseStations(_ data: Data) -> [Station] {
        guard let rows = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else { return [] }
        let names = RustTextColumn(rows.map { $0["name"] as? String })
        let urls = RustTextColumn(rows.map { $0["url_resolved"] as? String })
        let kept = names.with { nameText, nameLengths, hasName in
            urls.with { urlText, urlLengths, hasURL in
                Array(flows_tags_kept_station_rows(nameText, nameLengths, hasName,
                                                   urlText, urlLengths, hasURL, Int64(rows.count)))
            }
        }
        return kept.map { index in
            let row = rows[Int(index)]
            return Station(name: flows_tags_station_name(row["name"] as? String ?? "").text,
                           url: row["url_resolved"] as? String ?? "",
                           genre: genreWords(fromTags: row["tags"] as? String ?? ""),
                           votes: row["votes"] as? Int ?? 0,
                           latitude: row["geo_lat"] as? Double,
                           longitude: row["geo_long"] as? Double)
        }
    }

    /// The directory's comma-run of tags → the first three, as plain row
    /// detail ("country · news · talk").
    nonisolated static func genreWords(fromTags tags: String) -> String {
        flows_tags_genre_words(tags).text
    }

    /// The directory's common US genre tags — the word-finding helper's
    /// vocabulary when a spoken ask ("play me some old country") matches
    /// no station directly: the on-device model maps the ask onto ONE of
    /// these, and the search retries with that tag.
    nonisolated static let commonGenres = RustWordList.words(3)

    /// Two-letter state code → the full name the directory indexes by.
    nonisolated static func stateName(_ code: String) -> String? {
        let name = flows_tags_state_name(code).text
        return name.isEmpty ? nil : name
    }
}

/// Police/fire/EMS scanner: Broadcastify's terms allow no keyless stream
/// API, so FLOWS links OUT to their own public web player instead of
/// playing scanner audio in-app. The "near me" page locates the driver's
/// county through the browser (verified live: /listen/near/ asks the
/// browser for location and lists that county's feeds); the state
/// directory is the no-location-prompt alternative — Broadcastify's state
/// ids are US state FIPS codes (verified live: 48 → Texas, 6 → California).
enum ScannerLinks {
    static let broadcastifyNearMe =
        URL(string: "https://www.broadcastify.com/listen/near/")!

    /// OpenMHz — volunteer captures of trunked public-safety systems,
    /// RECORDINGS with a few minutes' delay (not live like Broadcastify).
    /// Their site sits behind a bot check (curl gets a challenge page), so
    /// the API can't be wired keylessly — link-out only, and the row says
    /// it's recordings.
    static let openMHz = URL(string: "https://openmhz.com/systems")!

    /// The state's own feed directory (driver taps their county there).
    static func stateFeedsURL(stateCode: String) -> URL? {
        let fips: [String: Int] = [
            "AL": 1, "AK": 2, "AZ": 4, "AR": 5, "CA": 6, "CO": 8, "CT": 9,
            "DE": 10, "DC": 11, "FL": 12, "GA": 13, "HI": 15, "ID": 16,
            "IL": 17, "IN": 18, "IA": 19, "KS": 20, "KY": 21, "LA": 22,
            "ME": 23, "MD": 24, "MA": 25, "MI": 26, "MN": 27, "MS": 28,
            "MO": 29, "MT": 30, "NE": 31, "NV": 32, "NH": 33, "NJ": 34,
            "NM": 35, "NY": 36, "NC": 37, "ND": 38, "OH": 39, "OK": 40,
            "OR": 41, "PA": 42, "RI": 44, "SC": 45, "SD": 46, "TN": 47,
            "TX": 48, "UT": 49, "VT": 50, "VA": 51, "WA": 53, "WV": 54,
            "WI": 55, "WY": 56,
        ]
        guard let id = fips[stateCode.uppercased()] else { return nil }
        return URL(string: "https://www.broadcastify.com/listen/stid/\(id)")
    }
}
