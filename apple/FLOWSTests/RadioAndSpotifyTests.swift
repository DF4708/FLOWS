// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// AM/FM directory parsing (radio-browser.info) and the Spotify Web API
/// request/response shapes — the pure halves of both features.
final class RadioAndSpotifyTests: XCTestCase {

    // MARK: radio-browser — mirror list

    func testParseServersDeduplicatesPerIPFamilyRepeats() {
        // The live payload repeats each mirror once per IP family (v4 + v6).
        let payload = """
        [{"ip":"91.98.4.78","name":"de1.api.radio-browser.info"},
         {"ip":"2a01:4f8::1","name":"de1.api.radio-browser.info"},
         {"ip":"1.2.3.4","name":"nl1.api.radio-browser.info"}]
        """.data(using: .utf8)!
        XCTAssertEqual(RadioBrowser.parseServers(payload),
                       ["de1.api.radio-browser.info", "nl1.api.radio-browser.info"])
    }

    func testParseServersToleratesGarbage() {
        XCTAssertEqual(RadioBrowser.parseServers(Data("not json".utf8)), [])
        XCTAssertEqual(RadioBrowser.parseServers(Data("[{\"ip\":\"1.2.3.4\"}]".utf8)), [])
    }

    func testServerHealthReadsTheStatsStatus() {
        XCTAssertTrue(RadioBrowser.serverLooksHealthy(
            Data(#"{"status":"OK","stations":57620}"#.utf8)))
        XCTAssertFalse(RadioBrowser.serverLooksHealthy(
            Data(#"{"error":"down"}"#.utf8)))
        XCTAssertFalse(RadioBrowser.serverLooksHealthy(Data("x".utf8)))
    }

    // MARK: radio-browser — station search URL

    func testSearchURLPinsUSWorkingHTTPSAndVoteOrder() throws {
        let url = try XCTUnwrap(RadioBrowser.searchURL(
            host: "de1.api.radio-browser.info", state: "Texas", name: nil))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://de1.api.radio-browser.info/json/stations/search?"))
        // The three structural filters: US only (banned-country services can
        // never appear), streams that worked at last check, https only.
        XCTAssertTrue(s.contains("countrycode=US"))
        XCTAssertTrue(s.contains("hidebroken=true"))
        XCTAssertTrue(s.contains("is_https=true"))
        XCTAssertTrue(s.contains("order=votes&reverse=true"))
        XCTAssertTrue(s.contains("state=Texas"))
    }

    func testSearchURLEncodesSpacesAndReservedCharacters() throws {
        let state = try XCTUnwrap(RadioBrowser.searchURL(
            host: "h", state: "New Mexico", name: nil))
        XCTAssertTrue(state.absoluteString.contains("state=New%20Mexico"))
        // "&" and "=" in a free-text term must not split the query string
        // (the Yelp truncation lesson).
        let name = try XCTUnwrap(RadioBrowser.searchURL(
            host: "h", state: nil, name: "rock & roll"))
        XCTAssertTrue(name.absoluteString.contains("name=rock%20%26%20roll"))
        XCTAssertFalse(name.absoluteString.contains("roll&"))
    }

    func testSearchURLGenreModeUsesTheTagParameter() throws {
        let url = try XCTUnwrap(RadioBrowser.searchURL(
            host: "h", state: nil, name: nil, tag: "classic country"))
        XCTAssertTrue(url.absoluteString.contains("tag=classic%20country"))
        XCTAssertFalse(url.absoluteString.contains("name="))
    }

    func testMergedSearchKeepsNameHitsFirstAndDropsDuplicates() {
        let a = RadioBrowser.Station(name: "KAAA", url: "https://a/1", genre: "", votes: 9)
        let b = RadioBrowser.Station(name: "KBBB", url: "https://b/1", genre: "", votes: 8)
        let dupB = RadioBrowser.Station(name: "kbbb", url: "https://b/2", genre: "", votes: 7)
        XCTAssertEqual(RadioBrowser.merged(nameHits: [a], tagHits: [b, dupB]),
                       [a, b])
        // One failed mode still serves the other.
        XCTAssertEqual(RadioBrowser.merged(nameHits: nil, tagHits: [b]), [b])
        XCTAssertEqual(RadioBrowser.merged(nameHits: [a], tagHits: nil), [a])
        // Both failed = a real failure, not "no stations found".
        XCTAssertNil(RadioBrowser.merged(nameHits: nil, tagHits: nil))
    }

    // MARK: radio-browser — station rows

    private let stationPayload = """
    [{"name":"KAAA Country","url_resolved":"https://a.example.com/live",
      "tags":"country,news,talk,extra-tag","votes":900},
     {"name":"KBBB Insecure","url_resolved":"http://b.example.com/live",
      "tags":"rock","votes":800},
     {"name":"KAAA Country","url_resolved":"https://a.example.com/live-hi",
      "tags":"country","votes":700},
     {"name":"KCCC Jazz","url_resolved":"https://a.example.com/live",
      "tags":"","votes":600},
     {"name":"  ","url_resolved":"https://d.example.com/live","tags":"x","votes":500},
     {"name":"KEEE Talk","url_resolved":"https://e.example.com/live",
      "tags":"talk","votes":400}]
    """.data(using: .utf8)!

    func testParseStationsFiltersToHTTPSAndDeduplicates() {
        let stations = RadioBrowser.parseStations(stationPayload)
        // KBBB is http (dropped); the second KAAA repeats the name (dropped);
        // KCCC repeats the first stream URL (dropped); the blank name drops.
        XCTAssertEqual(stations.map(\.name), ["KAAA Country", "KEEE Talk"])
        // Directory vote order (server-sorted) is preserved, not re-sorted.
        XCTAssertEqual(stations.map(\.votes), [900, 400])
        XCTAssertTrue(stations.allSatisfy { $0.url.hasPrefix("https://") })
    }

    func testGenreWordsTakeTheFirstThreeTags() {
        XCTAssertEqual(RadioBrowser.genreWords(fromTags: "country, news ,talk,extra"),
                       "country · news · talk")
        XCTAssertEqual(RadioBrowser.genreWords(fromTags: ""), "")
        XCTAssertEqual(RadioBrowser.genreWords(fromTags: " ,,rock"), "rock")
    }

    func testStationBridgesIntoTheTruckerRadioPlayerPath() {
        let station = RadioBrowser.Station(
            name: "KAAA", url: "https://a.example.com/live", genre: "", votes: 1)
        let channel = station.channel
        XCTAssertEqual(channel.streamURL?.absoluteString, "https://a.example.com/live")
        XCTAssertEqual(channel.detail, "AM/FM stream")   // plain words when tagless
    }

    func testStateNamesCoverEveryTwoLetterCode() {
        XCTAssertEqual(RadioBrowser.stateName("TX"), "Texas")
        XCTAssertEqual(RadioBrowser.stateName("dc"), "District of Columbia")
        XCTAssertEqual(RadioBrowser.stateName("NM"), "New Mexico")
        XCTAssertNil(RadioBrowser.stateName("PR"))   // directory has no PR index
        XCTAssertNil(RadioBrowser.stateName(""))
    }

    // MARK: scanner link-out

    func testScannerLinkIsBroadcastifysOwnPlayerOverHTTPS() {
        XCTAssertEqual(ScannerLinks.broadcastifyNearMe.scheme, "https")
        XCTAssertEqual(ScannerLinks.broadcastifyNearMe.host, "www.broadcastify.com")
    }

    func testStateFeedDirectoryUsesFIPSIds() {
        // Verified live: Broadcastify's stid values are US state FIPS codes.
        XCTAssertEqual(ScannerLinks.stateFeedsURL(stateCode: "TX")?.absoluteString,
                       "https://www.broadcastify.com/listen/stid/48")
        XCTAssertEqual(ScannerLinks.stateFeedsURL(stateCode: "ca")?.absoluteString,
                       "https://www.broadcastify.com/listen/stid/6")
        XCTAssertEqual(ScannerLinks.stateFeedsURL(stateCode: "DC")?.absoluteString,
                       "https://www.broadcastify.com/listen/stid/11")
        XCTAssertNil(ScannerLinks.stateFeedsURL(stateCode: "PR"))
        XCTAssertNil(ScannerLinks.stateFeedsURL(stateCode: ""))
    }

    // MARK: Siri hours-of-service line

    func testHOSLineSpeaksOnlyWhenTheClockMatters() {
        XCTAssertNil(SiriSummaries.hosLine(.ok))
        XCTAssertEqual(SiriSummaries.hosLine(.breakSoon(secondsUntilDue: 22 * 60)),
                       "Heads up: your 30-minute break is due in 22 minutes.")
        XCTAssertEqual(SiriSummaries.hosLine(.breakDue),
                       "Your 30-minute break is due now.")
        XCTAssertEqual(SiriSummaries.hosLine(.limitReached),
                       "You've hit the 11-hour driving limit — time to stop.")
    }

    // MARK: Siri replies — spoken text is UI, so the wording is pinned

    func testSpokenMilesReadNaturally() {
        XCTAssertEqual(SiriSummaries.spokenMiles(meters: 1609.344), "1 mile")
        XCTAssertEqual(SiriSummaries.spokenMiles(meters: 640), "0.4 miles")
        XCTAssertEqual(SiriSummaries.spokenMiles(meters: 5 * 1609.344), "5 miles")
        XCTAssertEqual(SiriSummaries.spokenMiles(meters: 3.72 * 1609.344), "3.7 miles")
        XCTAssertEqual(SiriSummaries.spokenMiles(meters: 212.4 * 1609.344), "212 miles")
    }

    func testSpokenTimeReadsNaturally() {
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: 20), "under a minute")
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: 60), "1 minute")
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: 45 * 60), "45 minutes")
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: 2 * 3600), "2 hours")
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: 3 * 3600 + 61 * 60 + 30),
                       "4 hours 2 minutes")
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: 3660), "1 hour 1 minute")
    }

    func testAddedStopReplyNamesThePlaceAndDistance() {
        XCTAssertEqual(
            SiriSummaries.addedStop(name: "Starbucks", meters: 12 * 1609.344),
            "Added Starbucks, about 12 miles ahead. Directions updated.")
        XCTAssertEqual(
            SiriSummaries.addedStop(name: "Starbucks", meters: nil),
            "Added Starbucks to the route. Directions updated.")
    }

    func testRoadAheadSummarizesDistanceTimeAndAlerts() {
        XCTAssertEqual(
            SiriSummaries.roadAhead(remainingMeters: 212 * 1609.344,
                                    remainingSeconds: 3 * 3600 + 10 * 60,
                                    alertEvents: []),
            "About 212 miles and 3 hours 10 minutes to go. "
            + "No weather alerts on the route.")
        XCTAssertEqual(
            SiriSummaries.roadAhead(remainingMeters: 8 * 1609.344,
                                    remainingSeconds: 12 * 60,
                                    alertEvents: ["Severe Thunderstorm Warning",
                                                  "Severe Thunderstorm Warning"]),
            "About 8 miles and 12 minutes to go. "
            + "One weather alert ahead: Severe Thunderstorm Warning.")
        XCTAssertEqual(
            SiriSummaries.roadAhead(remainingMeters: 8 * 1609.344,
                                    remainingSeconds: 12 * 60,
                                    alertEvents: ["Flood Warning", "High Wind Warning"]),
            "About 8 miles and 12 minutes to go. "
            + "2 weather alerts ahead: Flood Warning, High Wind Warning.")
    }

    // MARK: Siri add-a-stop name matching

    func testAskedNameMatchesStandaloneWordRuns() {
        XCTAssertTrue(BrandKnowledge.askedName("Starbucks", matches: "Starbucks Coffee"))
        XCTAssertTrue(BrandKnowledge.askedName("Buc-ee's", matches: "Buc-ee's #34"))
        XCTAssertTrue(BrandKnowledge.askedName("Yellowstone",
                                               matches: "Yellowstone National Park"))
        XCTAssertTrue(BrandKnowledge.askedName("McDonald's", matches: "McDonalds"))
        // Substring-of-a-word must NOT match — "Star" is not "Starbucks".
        XCTAssertFalse(BrandKnowledge.askedName("Star", matches: "Starbucks"))
        XCTAssertFalse(BrandKnowledge.askedName("Starbucks", matches: "Joe's Coffee"))
    }

    // MARK: in-place control — the truth table every surface consults

    func testInPlaceControlTruthTableCoversEveryProvider() {
        for provider in MusicProvider.allCases {
            let keyless = provider == .appleMusic
            // Keyless floor off-mac: Apple Music only.
            XCTAssertEqual(provider.controllable(onMac: false, spotifyLinked: false),
                           keyless, "\(provider.rawValue) keyless")
            // A Spotify token upgrades EXACTLY one provider — Spotify. No
            // other service publishes a control API, so no token, key, or
            // setting may ever flip the rest (the survey in DATA_FEEDS §13).
            XCTAssertEqual(provider.controllable(onMac: false, spotifyLinked: true),
                           keyless || provider == .spotify,
                           "\(provider.rawValue) with Spotify token")
            // macOS adds Apple-Events Spotify; the rest stay uncontrollable.
            XCTAssertEqual(provider.controllable(onMac: true, spotifyLinked: false),
                           keyless || provider == .spotify,
                           "\(provider.rawValue) on macOS")
        }
    }

    // MARK: Spotify Web API — request shapes

    func testTransportCallsMapToThePlayerEndpoints() {
        XCTAssertEqual(SpotifyWebAPI.playPauseCall(isPlaying: true),
                       SpotifyWebAPI.Call(method: "PUT", path: "/v1/me/player/pause"))
        XCTAssertEqual(SpotifyWebAPI.playPauseCall(isPlaying: false),
                       SpotifyWebAPI.Call(method: "PUT", path: "/v1/me/player/play"))
        XCTAssertEqual(SpotifyWebAPI.next.method, "POST")
        XCTAssertEqual(SpotifyWebAPI.next.path, "/v1/me/player/next")
        XCTAssertEqual(SpotifyWebAPI.previous.path, "/v1/me/player/previous")
        XCTAssertEqual(SpotifyWebAPI.playerState.method, "GET")
    }

    func testOrderCallsMapShuffleAndLoop() {
        XCTAssertEqual(SpotifyWebAPI.shuffleCall(on: true).path,
                       "/v1/me/player/shuffle?state=true")
        XCTAssertEqual(SpotifyWebAPI.shuffleCall(on: false).path,
                       "/v1/me/player/shuffle?state=false")
        XCTAssertEqual(SpotifyWebAPI.repeatCall(all: true).path,
                       "/v1/me/player/repeat?state=context")
        XCTAssertEqual(SpotifyWebAPI.repeatCall(all: false).path,
                       "/v1/me/player/repeat?state=off")
    }

    func testURLRequestCarriesTheBearerToken() throws {
        let request = try XCTUnwrap(SpotifyWebAPI.urlRequest(
            for: SpotifyWebAPI.next, token: "abc123"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.spotify.com/v1/me/player/next")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer abc123")
    }

    // MARK: Spotify Web API — player state

    func testParsePlayerStateReadsTheFourDisplayedFields() throws {
        let payload = """
        {"is_playing":true,"shuffle_state":true,"repeat_state":"off",
         "item":{"name":"Copperhead Road"}}
        """.data(using: .utf8)!
        let state = try XCTUnwrap(SpotifyWebAPI.parsePlayerState(payload))
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.shuffle)
        XCTAssertFalse(state.repeatOn)
        XCTAssertEqual(state.track, "Copperhead Road")
    }

    func testParsePlayerStateSurvivesMissingItem() throws {
        let payload = #"{"is_playing":false,"repeat_state":"context"}"#
            .data(using: .utf8)!
        let state = try XCTUnwrap(SpotifyWebAPI.parsePlayerState(payload))
        XCTAssertFalse(state.isPlaying)
        XCTAssertTrue(state.repeatOn)
        XCTAssertEqual(state.track, "")
        XCTAssertNil(SpotifyWebAPI.parsePlayerState(Data()))
    }

    func testOrderCycleMirrorsThePlayOrderEnum() {
        XCTAssertEqual(SpotifyWebAPI.order(shuffle: true, repeatOn: false), .shuffle)
        XCTAssertEqual(SpotifyWebAPI.order(shuffle: true, repeatOn: true), .shuffle)
        XCTAssertEqual(SpotifyWebAPI.order(shuffle: false, repeatOn: true), .loop)
        XCTAssertEqual(SpotifyWebAPI.order(shuffle: false, repeatOn: false), .ordered)
    }

    // MARK: Spotify Web API — plain-words failures

    func testPlainWordsNameTheOneFixPerFailure() {
        XCTAssertNil(SpotifyWebAPI.plainWords(status: 200))
        XCTAssertNil(SpotifyWebAPI.plainWords(status: 204))
        // Each failure names the driver's next move, no jargon.
        XCTAssertEqual(SpotifyWebAPI.plainWords(status: 401),
                       "Spotify token expired or wrong. Paste a fresh one in Settings.")
        XCTAssertEqual(SpotifyWebAPI.plainWords(status: 403),
                       "Spotify says no — remote control needs Spotify Premium.")
        XCTAssertEqual(SpotifyWebAPI.plainWords(status: 404),
                       "No Spotify player is on. Open Spotify and play one song first.")
        XCTAssertEqual(SpotifyWebAPI.plainWords(status: 429),
                       "Spotify is busy. Wait a moment and try again.")
        XCTAssertEqual(SpotifyWebAPI.plainWords(status: 500),
                       "Spotify didn't answer. Try again.")
    }
}
