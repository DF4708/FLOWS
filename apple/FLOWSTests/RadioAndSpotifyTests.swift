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
