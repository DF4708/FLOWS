// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

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

        var id: String { url }

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

    /// Top-voted stations for the state the vehicle is in (nationwide list
    /// when the state is unknown — no GPS fix yet).
    func searchNearby(stateCode: String?) async {
        await run(state: stateCode.flatMap { Self.stateName($0) }, name: nil)
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
            for candidate in Self.parseServers(data).shuffled() {
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
    nonisolated static func parseServers(_ data: Data) -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty,
                  seen.insert(name).inserted else { return nil }
            return name
        }
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
                                      name: String?, tag: String? = nil) -> URL? {
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
        return URL(string: "https://\(host)/json/stations/search?\(query)")
    }

    /// Merge the two free-text modes: name matches lead, genre (tag)
    /// matches follow, duplicates drop. nil only when BOTH requests failed
    /// — one working mode still serves.
    nonisolated static func merged(nameHits: [Station]?,
                                   tagHits: [Station]?) -> [Station]? {
        if nameHits == nil && tagHits == nil { return nil }
        var seenURL = Set<String>()
        var seenName = Set<String>()
        return ((nameHits ?? []) + (tagHits ?? [])).filter {
            seenURL.insert($0.url).inserted
                && seenName.insert($0.name.lowercased()).inserted
        }
    }

    /// Station rows → playable list: HTTPS streams only (belt and braces —
    /// the server already filtered), de-duplicated by stream URL and by
    /// name (the directory lists one station once per bitrate), directory
    /// vote order preserved.
    nonisolated static func parseStations(_ data: Data) -> [Station] {
        guard let rows = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else { return [] }
        var seenURL = Set<String>()
        var seenName = Set<String>()
        return rows.compactMap { row in
            guard let name = (row["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let url = row["url_resolved"] as? String,
                  url.hasPrefix("https://"),
                  seenURL.insert(url).inserted,
                  seenName.insert(name.lowercased()).inserted else { return nil }
            return Station(name: name,
                           url: url,
                           genre: genreWords(fromTags: row["tags"] as? String ?? ""),
                           votes: row["votes"] as? Int ?? 0)
        }
    }

    /// The directory's comma-run of tags → the first three, as plain row
    /// detail ("country · news · talk").
    nonisolated static func genreWords(fromTags tags: String) -> String {
        tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " · ")
    }

    /// The directory's common US genre tags — the word-finding helper's
    /// vocabulary when a spoken ask ("play me some old country") matches
    /// no station directly: the on-device model maps the ask onto ONE of
    /// these, and the search retries with that tag.
    static let commonGenres = [
        "country", "classic country", "bluegrass", "folk",
        "rock", "classic rock", "metal", "pop", "top 40",
        "oldies", "80s", "90s", "jazz", "blues", "classical",
        "hip-hop", "r&b", "soul", "dance", "gospel", "christian",
        "spanish", "regional mexican", "news", "talk", "sports",
    ]

    /// Two-letter state code → the full name the directory indexes by.
    nonisolated static func stateName(_ code: String) -> String? {
        let names: [String: String] = [
            "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas",
            "CA": "California", "CO": "Colorado", "CT": "Connecticut",
            "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida",
            "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois",
            "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky",
            "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
            "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
            "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
            "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire",
            "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
            "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
            "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
            "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
            "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
            "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
            "WI": "Wisconsin", "WY": "Wyoming",
        ]
        return names[code.uppercased()]
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
