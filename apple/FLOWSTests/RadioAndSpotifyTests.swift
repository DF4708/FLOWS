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

    // MARK: Siri spoken announcements

    func testSpokenClipCutsAtSentenceEdges() {
        XCTAssertEqual(SiriSummaries.spokenClip("Short."), "Short.")
        let sentences = "First sentence here. "
            + String(repeating: "second part goes on ", count: 30)
        XCTAssertEqual(SiriSummaries.spokenClip(sentences), "First sentence here.")
        let noPeriods = String(repeating: "word ", count: 60)
        XCTAssertLessThanOrEqual(SiriSummaries.spokenClip(noPeriods).count, 220)
    }

    func testFasterRouteOfferAsksForThePlainYes() {
        XCTAssertEqual(
            SiriSummaries.fasterRouteOffer(minutes: 12),
            "Traffic ahead adds about 12 minutes. "
            + "A faster route is ready — say yes to take it.")
        XCTAssertTrue(SiriSummaries.fasterRouteOffer(minutes: 1)
            .contains("about 1 minute."))
    }

    func testYesNoWordsReadPlainReplies() {
        XCTAssertEqual(YesNoWords.interpret("yes"), true)
        XCTAssertEqual(YesNoWords.interpret("Yeah, take it"), true)
        XCTAssertEqual(YesNoWords.interpret("okay sure"), true)
        XCTAssertEqual(YesNoWords.interpret("go ahead"), true)
        XCTAssertEqual(YesNoWords.interpret("no"), false)
        XCTAssertEqual(YesNoWords.interpret("no thanks"), false)
        XCTAssertEqual(YesNoWords.interpret("keep this route"), false)
        // A mixed reply refuses — "yeah, no" is a no.
        XCTAssertEqual(YesNoWords.interpret("yeah no"), false)
        // Silence or chatter is NEVER guessed.
        XCTAssertNil(YesNoWords.interpret(""))
        XCTAssertNil(YesNoWords.interpret("what was that"))
        // "Nose" must not read as "no" — whole words only.
        XCTAssertNil(YesNoWords.interpret("nose"))
    }

    func testVoicePickTakesNamesKeywordsAndPlainYes() {
        let options = ["Taco Bell", "El Rays", "Chipotle"]
        // The user's exact script: "yes, let's go to Taco Bell".
        XCTAssertEqual(VoicePick.choose(reply: "yes, let's go to Taco Bell",
                                        options: options), .picked(0))
        XCTAssertEqual(VoicePick.choose(reply: "El Rays please",
                                        options: options), .picked(1))
        // A bare yes takes the FIRST offer.
        XCTAssertEqual(VoicePick.choose(reply: "yes", options: options), .picked(0))
        XCTAssertEqual(VoicePick.choose(reply: "no", options: options), .declined)
        XCTAssertEqual(VoicePick.choose(reply: "hmm what", options: options), .unclear)
        // Cuisine step: "I want mexican" from the category list.
        let cuisines = ["Fast food", "Pizza", "American", "Mexican", "Greek"]
        XCTAssertEqual(VoicePick.choose(reply: "I want mexican",
                                        options: cuisines), .picked(3))
        XCTAssertEqual(VoicePick.choose(reply: "fast food I guess",
                                        options: cuisines), .picked(0))
    }

    func testPlaceReplyHandlesChangesOfMind() {
        let places = ["Athens Gyro", "Olive Grove"]
        let cuisines = ["Fast food", "Pizza", "American", "Mexican", "Greek"]
        // Straight picks still work at this step.
        XCTAssertEqual(VoicePick.placeReply("Olive Grove sounds good",
                                            places: places, cuisines: cuisines),
                       .picked(1))
        XCTAssertEqual(VoicePick.placeReply("yes", places: places, cuisines: cuisines),
                       .picked(0))
        // The change of mind: picked Greek, now wants Mexican — naming the
        // cuisine switches the earlier answer with no back-word needed.
        XCTAssertEqual(VoicePick.placeReply("actually I want Mexican instead",
                                            places: places, cuisines: cuisines),
                       .switchCuisine(3))
        // The explicit third option: back a step.
        XCTAssertEqual(VoicePick.placeReply("go back",
                                            places: places, cuisines: cuisines),
                       .backToCuisine)
        XCTAssertEqual(VoicePick.placeReply("something else",
                                            places: places, cuisines: cuisines),
                       .backToCuisine)
        // A place hit beats everything — "Athens Gyro" wins even though
        // the sentence also says "different".
        XCTAssertEqual(VoicePick.placeReply("no wait, Athens Gyro is a different one, let's do that",
                                            places: places, cuisines: cuisines),
                       .picked(0))
        XCTAssertEqual(VoicePick.placeReply("no", places: places, cuisines: cuisines),
                       .declined)
        XCTAssertEqual(VoicePick.placeReply("hmm", places: places, cuisines: cuisines),
                       .unclear)
        // Non-food dialogues pass no cuisines — back-words still back out.
        XCTAssertEqual(VoicePick.placeReply("something different",
                                            places: places, cuisines: []),
                       .backToCuisine)
    }

    func testCommonGenresAreCleanDirectoryTags() {
        // The word-finding vocabulary must be directory-shaped: lowercase
        // tags, unique, no stray whitespace — and broad enough to be useful.
        let genres = RadioBrowser.commonGenres
        XCTAssertGreaterThanOrEqual(genres.count, 20)
        XCTAssertEqual(Set(genres).count, genres.count)
        for genre in genres {
            XCTAssertEqual(genre, genre.lowercased(), genre)
            XCTAssertEqual(genre, genre.trimmingCharacters(in: .whitespaces), genre)
            XCTAssertFalse(genre.isEmpty)
        }
        XCTAssertTrue(genres.contains("classic country"))
    }

    // MARK: on-device clarifier — the model's reply parses safely

    func testClarifierParsesTheModelsNumberSafely() {
        XCTAssertEqual(IntentClarifier.optionIndex(fromModelText: "2", optionCount: 3), 1)
        XCTAssertEqual(IntentClarifier.optionIndex(fromModelText: "Option 3.", optionCount: 3), 2)
        // 0 = the model says nothing matches — honored, never coerced.
        XCTAssertNil(IntentClarifier.optionIndex(fromModelText: "0", optionCount: 3))
        XCTAssertNil(IntentClarifier.optionIndex(fromModelText: "7", optionCount: 3))
        XCTAssertNil(IntentClarifier.optionIndex(fromModelText: "none of them", optionCount: 3))
        XCTAssertNil(IntentClarifier.optionIndex(fromModelText: "", optionCount: 3))
        // The FIRST number wins — chatter after it can't redirect the pick.
        XCTAssertEqual(IntentClarifier.optionIndex(
            fromModelText: "1 (though 2 is close)", optionCount: 3), 0)
    }

    // MARK: text-size slider — screen-clamped bounds

    func testTextScaleCapsFollowTheScreenWidth() {
        // Phone-width windows stop before the accessibility tiers.
        XCTAssertEqual(TextScale.steps[TextScale.maxStepIndex(forWidthPoints: 375)],
                       .xxxLarge)
        // Mid widths (big phones, split view) allow the small accessibility
        // sizes; only tablet/desktop widths offer the largest.
        XCTAssertEqual(TextScale.steps[TextScale.maxStepIndex(forWidthPoints: 650)],
                       .accessibility2)
        XCTAssertEqual(TextScale.steps[TextScale.maxStepIndex(forWidthPoints: 1200)],
                       .accessibility5)
    }

    func testTextScaleRangePinsChoicesAndClampsTheSystem() {
        let maxIdx = TextScale.maxStepIndex(forWidthPoints: 375)
        // Follow-system (−1): free below, capped above.
        XCTAssertEqual(TextScale.range(chosenIndex: -1, maxIndex: maxIdx),
                       .xSmall ... .xxxLarge)
        // A picked step pins exactly.
        let large = TextScale.index(of: .large)
        XCTAssertEqual(TextScale.range(chosenIndex: large, maxIndex: maxIdx),
                       .large ... .large)
        // A pick beyond the screen's cap clamps to the cap — words must
        // never warp off the edge no matter what was stored.
        XCTAssertEqual(TextScale.range(chosenIndex: 99, maxIndex: maxIdx),
                       .xxxLarge ... .xxxLarge)
        XCTAssertEqual(TextScale.range(chosenIndex: 0, maxIndex: 99),
                       .small ... .small)
    }

    func testSpokenTurnDistancesReadLikeANavigator() {
        XCTAssertEqual(SiriSummaries.spokenTurnDistance(meters: 3 * 1609.344), "In 3 miles")
        XCTAssertEqual(SiriSummaries.spokenTurnDistance(meters: 1609), "In a mile")
        XCTAssertEqual(SiriSummaries.spokenTurnDistance(meters: 800), "In half a mile")
        XCTAssertEqual(SiriSummaries.spokenTurnDistance(meters: 400), "In a quarter mile")
        XCTAssertEqual(SiriSummaries.spokenTurnDistance(meters: 152), "In 500 feet")
        XCTAssertEqual(SiriSummaries.spokenTurnDistance(meters: 10), "In 100 feet")
    }

    func testEmergencyAnnouncementFramesAmberAndWeatherDifferently() {
        let amber = SiriSummaries.emergencyAnnouncement(
            event: "Child Abduction Emergency",
            headline: "AMBER Alert: red pickup northbound", action: .monitor)
        XCTAssertTrue(amber.hasPrefix("Emergency alert: Child Abduction Emergency."))
        XCTAssertTrue(amber.contains("AMBER Alert: red pickup northbound."))
        XCTAssertTrue(amber.hasSuffix("call 911 — do not approach."))
        XCTAssertEqual(
            SiriSummaries.emergencyAnnouncement(
                event: "Tornado Warning",
                headline: "Tornado Warning until 5 PM.", action: .shelter),
            "Weather alert on your route: Tornado Warning. "
            + "Tornado Warning until 5 PM. FLOWS is showing shelter options.")
        XCTAssertTrue(SiriSummaries.emergencyAnnouncement(
            event: "High Wind Warning", headline: nil, action: .restArea)
            .hasSuffix("rest area."))
        XCTAssertTrue(SiriSummaries.emergencyAnnouncement(
            event: "Wind Advisory", headline: nil, action: .monitor)
            .hasSuffix("when it's safe."))
    }

    func testOpenMHzLinkIsHTTPS() {
        XCTAssertEqual(ScannerLinks.openMHz.scheme, "https")
        XCTAssertEqual(ScannerLinks.openMHz.host, "openmhz.com")
    }

    func testWeatherWordsRouteToTheNOAARelayPath() {
        XCTAssertTrue(VoiceCommands.wantsWeatherRadio("the weather radio"))
        XCTAssertTrue(VoiceCommands.wantsWeatherRadio("Play NOAA please"))
        XCTAssertTrue(VoiceCommands.wantsWeatherRadio("Weather"))
        XCTAssertFalse(VoiceCommands.wantsWeatherRadio("classic country"))
        XCTAssertFalse(VoiceCommands.wantsWeatherRadio("KMFA"))
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

    // MARK: search deep links — the no-API integration layer

    func testEveryProviderHasAnEncodedHTTPSSearchLink() {
        for provider in MusicProvider.allCases {
            let url = provider.searchURL(query: "classic country & hits")
            XCTAssertEqual(url.scheme, "https", provider.rawValue)
            XCTAssertFalse(url.absoluteString.contains(" "), provider.rawValue)
            // "&" inside the TERM must encode — it would split the query
            // string (the same Yelp lesson as everywhere else).
            XCTAssertFalse(url.absoluteString.contains("&hits"), provider.rawValue)
        }
        // Patterns pinned to what the live probes verified.
        XCTAssertEqual(
            MusicProvider.youtubeMusic.searchURL(query: "road songs").absoluteString,
            "https://music.youtube.com/search?q=road%20songs")
        XCTAssertEqual(
            MusicProvider.jioSaavn.searchURL(query: "hindi").absoluteString,
            "https://www.jiosaavn.com/search/song/hindi")
        XCTAssertEqual(
            MusicProvider.siriusXM.searchURL(query: "classic country").absoluteString,
            "https://www.siriusxm.com/search?activeTab=all&q=classic%20country")
    }

    // MARK: radio as a music service — the station queue

    func testQueueAdvanceWrapsBothWays() {
        // Next past the end wraps to the first station, previous past the
        // start wraps to the last — a genre run never dead-ends.
        XCTAssertEqual(TruckerRadio.advance(index: 0, count: 3, by: 1), 1)
        XCTAssertEqual(TruckerRadio.advance(index: 2, count: 3, by: 1), 0)
        XCTAssertEqual(TruckerRadio.advance(index: 0, count: 3, by: -1), 2)
        XCTAssertEqual(TruckerRadio.advance(index: 1, count: 3, by: -1), 0)
        // One-station queue: next/previous stay put rather than crash.
        XCTAssertEqual(TruckerRadio.advance(index: 0, count: 1, by: 1), 0)
        XCTAssertEqual(TruckerRadio.advance(index: 0, count: 1, by: -1), 0)
        // Empty queue is safe (no stations found yet).
        XCTAssertEqual(TruckerRadio.advance(index: 0, count: 0, by: 1), 0)
        XCTAssertEqual(TruckerRadio.advance(index: 5, count: 0, by: -1), 0)
    }

    // MARK: buffer grace — the signal dropping isn't the music stopping

    func testRadioGraceUsesTheMeasuredBufferWithinBounds() {
        // Our own player, so the remaining audio is MEASURED: a 12-second
        // buffer means 12 seconds before the music can actually die.
        XCTAssertEqual(
            PlaybackGrace.graceSeconds(for: .radio, measuredBuffer: 12), 12)
        // A nearly-empty buffer still gets the floor — a stream tuned one
        // second ago hasn't loaded anything yet.
        XCTAssertEqual(
            PlaybackGrace.graceSeconds(for: .radio, measuredBuffer: 0.5),
            PlaybackGrace.radioFloorSeconds)
        // An absurd buffer can't hold the handoff open forever.
        XCTAssertEqual(
            PlaybackGrace.graceSeconds(for: .radio, measuredBuffer: 600),
            PlaybackGrace.radioCapSeconds)
        // Unknown (nothing playing yet) falls back to the floor, never NaN.
        XCTAssertEqual(PlaybackGrace.graceSeconds(for: .radio),
                       PlaybackGrace.radioFloorSeconds)
        XCTAssertEqual(
            PlaybackGrace.graceSeconds(for: .radio, measuredBuffer: .nan),
            PlaybackGrace.radioFloorSeconds)
    }

    func testOtherPlayersUseTheirDocumentedCaps() {
        // Their buffers aren't inspectable, so these bound the wait; the
        // real trigger is the player reporting it stopped.
        XCTAssertEqual(PlaybackGrace.graceSeconds(for: .appleMusicCloud),
                       PlaybackGrace.appleMusicCapSeconds)
        XCTAssertEqual(PlaybackGrace.graceSeconds(for: .spotify),
                       PlaybackGrace.spotifyCapSeconds)
        // A measured value can't leak in from a player we don't own.
        XCTAssertEqual(
            PlaybackGrace.graceSeconds(for: .appleMusicCloud, measuredBuffer: 3),
            PlaybackGrace.appleMusicCapSeconds)
        // Every wait rides out a short tunnel without stranding anyone.
        for source: PlaybackGrace.Source in [.radio, .appleMusicCloud, .spotify] {
            let grace = PlaybackGrace.graceSeconds(for: source, measuredBuffer: 20)
            XCTAssertGreaterThanOrEqual(grace, 4, "\(source)")
            XCTAssertLessThanOrEqual(grace, 45, "\(source)")
        }
    }

    func testOtherAppsAreWatchedNotGuessed() {
        // No service publishes a read-ahead figure, so this is a WATCH
        // ceiling, not a buffer estimate: it must outlast the others,
        // because audio still playing at the ceiling is left alone.
        XCTAssertEqual(PlaybackGrace.graceSeconds(for: .otherApp),
                       PlaybackGrace.otherAppWatchSeconds)
        XCTAssertGreaterThan(PlaybackGrace.otherAppWatchSeconds,
                             PlaybackGrace.spotifyCapSeconds)
        // A measured buffer is meaningless for a player we don't own —
        // it must never shorten the watch.
        XCTAssertEqual(
            PlaybackGrace.graceSeconds(for: .otherApp, measuredBuffer: 2),
            PlaybackGrace.otherAppWatchSeconds)
    }

    // MARK: learned buffer depth — measurement replacing the guess

    func testLearnedMeanTracksTheNewestObservations() {
        // First sample seeds the mean outright.
        XCTAssertEqual(BufferLearning.updated(mean: nil, sample: 20), 20)
        // Then it moves toward each new sample by alpha.
        let second = try! XCTUnwrap(BufferLearning.updated(mean: 20, sample: 30))
        XCTAssertEqual(second, 20 * 0.65 + 30 * 0.35, accuracy: 0.0001)
        // A service that consistently buffers ~10 s converges there from
        // a bad starting estimate, rather than averaging forever.
        var mean: Double? = 40
        for _ in 0..<12 { mean = BufferLearning.updated(mean: mean, sample: 10) }
        XCTAssertEqual(try XCTUnwrap(mean), 10, accuracy: 0.5)
    }

    func testImplausibleSamplesAreDiscardedNotClamped() {
        // Sub-second: the driver hit stop as the signal died.
        XCTAssertEqual(BufferLearning.updated(mean: 20, sample: 0.2), 20)
        // Minutes: the audio was local, or signal returned unnoticed.
        XCTAssertEqual(BufferLearning.updated(mean: 20, sample: 600), 20)
        XCTAssertEqual(BufferLearning.updated(mean: 20, sample: .nan), 20)
        // Discarded, never folded in — a clamp would drag the estimate
        // toward a value that was never actually observed.
        XCTAssertFalse(BufferLearning.isUsable(sample: 0.2))
        XCTAssertFalse(BufferLearning.isUsable(sample: 600))
        XCTAssertTrue(BufferLearning.isUsable(sample: 12))
    }

    func testPriorLeadsUntilEnoughSamplesExist() {
        // One or two outages is an anecdote — keep the documented prior.
        XCTAssertEqual(
            BufferLearning.waitSeconds(prior: 30, learnedMean: 9, samples: 2), 30)
        XCTAssertEqual(
            BufferLearning.waitSeconds(prior: 30, learnedMean: nil, samples: 9), 30)
        // Past the gate, this driver's own measurement wins outright.
        XCTAssertEqual(
            BufferLearning.waitSeconds(
                prior: 30, learnedMean: 9,
                samples: BufferLearning.minSamplesToTrust), 9)
    }

    func testLearningIsKeyedPerServiceAndRadioTechnology() {
        // Each service buffers differently — their samples must not mix.
        XCTAssertNotEqual(
            BufferLearning.contextKey(service: "spotify", radioTechnology: "LTE"),
            BufferLearning.contextKey(service: "appleMusic", radioTechnology: "LTE"))
        // And the same service behaves differently on 5G vs EDGE, so LTE
        // samples must not pollute the weak-signal estimate.
        XCTAssertNotEqual(
            BufferLearning.contextKey(service: "spotify", radioTechnology: "LTE"),
            BufferLearning.contextKey(service: "spotify", radioTechnology: "EDGE"))
        XCTAssertEqual(
            BufferLearning.contextKey(service: "spotify", radioTechnology: nil),
            BufferLearning.contextKey(service: "spotify", radioTechnology: nil))
    }

    // MARK: signal quality — staging the switch before the music dies

    func testRadioTechnologyMapsToTheRightTier() {
        XCTAssertEqual(SignalQuality.tier(radioTechnology: "CTRadioAccessTechnologyLTE",
                                          onWiFi: false, offline: false), .strong)
        XCTAssertEqual(SignalQuality.tier(radioTechnology: "CTRadioAccessTechnologyNRNSA",
                                          onWiFi: false, offline: false), .strong)
        // The classic dead-zone approach: a fallback to EDGE happens
        // BEFORE the throughput collapse that starves a buffer.
        XCTAssertEqual(SignalQuality.tier(radioTechnology: "CTRadioAccessTechnologyEdge",
                                          onWiFi: false, offline: false), .weak)
        XCTAssertEqual(SignalQuality.tier(radioTechnology: "CTRadioAccessTechnologyGPRS",
                                          onWiFi: false, offline: false), .weak)
        XCTAssertEqual(SignalQuality.tier(radioTechnology: "CTRadioAccessTechnologyHSDPA",
                                          onWiFi: false, offline: false), .fair)
        XCTAssertEqual(SignalQuality.tier(radioTechnology: nil,
                                          onWiFi: true, offline: false), .strong)
        XCTAssertEqual(SignalQuality.tier(radioTechnology: "CTRadioAccessTechnologyLTE",
                                          onWiFi: false, offline: true), .offline)
    }

    func testPreStagingFiresOnFailureSignsButNotWhenAlreadyTooLate() {
        // A weak radio technology alone is enough to get ready.
        XCTAssertTrue(SignalQuality.shouldPreStage(
            tier: .weak, bufferDraining: false, recentStalls: 0))
        // So is the actual mechanism of failure, observed on our own
        // player: the buffer being consumed faster than it refills.
        XCTAssertTrue(SignalQuality.shouldPreStage(
            tier: .strong, bufferDraining: true, recentStalls: 0))
        XCTAssertTrue(SignalQuality.shouldPreStage(
            tier: .strong, bufferDraining: false, recentStalls: 1))
        // A healthy link stages nothing.
        XCTAssertFalse(SignalQuality.shouldPreStage(
            tier: .strong, bufferDraining: false, recentStalls: 0))
        // Already offline: too late to fetch anything, so don't try.
        XCTAssertFalse(SignalQuality.shouldPreStage(
            tier: .offline, bufferDraining: true, recentStalls: 3))
    }

    func testBufferDrainingNeedsARealDrop() {
        XCTAssertTrue(SignalQuality.isDraining(previous: 20, current: 12))
        // Normal jitter around a steady buffer isn't a failure sign.
        XCTAssertFalse(SignalQuality.isDraining(previous: 20, current: 19.5))
        XCTAssertFalse(SignalQuality.isDraining(previous: 12, current: 20))
        XCTAssertFalse(SignalQuality.isDraining(previous: nil, current: 12))
        XCTAssertFalse(SignalQuality.isDraining(previous: 20, current: nil))
    }

    // MARK: offline handoff — what still plays when the signal drops

    func testHandoffPrefersLocalMusicThenLikeForLikeRadio() {
        // Downloaded music is the only thing that plays with NO signal.
        XCTAssertEqual(
            PlaybackFallback.onConnectionLost(
                isPlaying: true, needsNetwork: true,
                hasLocalMusic: true, lastGenre: "rock"),
            .localLibrary)
        // Nothing saved on the phone → a station of the same kind (the
        // degraded-signal rung: a low-bitrate stream may still flow).
        XCTAssertEqual(
            PlaybackFallback.onConnectionLost(
                isPlaying: true, needsNetwork: true,
                hasLocalMusic: false, lastGenre: "rock"),
            .radio(genre: "rock"))
        // No local music and nothing to match → say so, don't pretend.
        XCTAssertEqual(
            PlaybackFallback.onConnectionLost(
                isPlaying: true, needsNetwork: true,
                hasLocalMusic: false, lastGenre: nil),
            .nothingAvailable)
        XCTAssertEqual(
            PlaybackFallback.onConnectionLost(
                isPlaying: true, needsNetwork: true,
                hasLocalMusic: false, lastGenre: "   "),
            .nothingAvailable)
    }

    func testHandoffNeverInterruptsPlaybackThatSurvivesOffline() {
        // Local files already playing: the best handoff is none at all.
        XCTAssertEqual(
            PlaybackFallback.onConnectionLost(
                isPlaying: true, needsNetwork: false,
                hasLocalMusic: true, lastGenre: "rock"),
            .keepPlaying)
        // Nothing playing: nothing to save.
        XCTAssertEqual(
            PlaybackFallback.onConnectionLost(
                isPlaying: false, needsNetwork: true,
                hasLocalMusic: true, lastGenre: "rock"),
            .keepPlaying)
        XCTAssertNil(PlaybackFallback.spokenLine(for: .keepPlaying))
    }

    func testSwitchBackNeedsAHeldConnectionAndNoDriverChoice() {
        // The happy path: FLOWS moved it, signal held, driver stayed put.
        XCTAssertTrue(PlaybackFallback.shouldRestore(
            handedOff: true, connectionHeld: true, driverChoseSince: false))
        // A blink that didn't hold must NOT ping-pong the driver back.
        XCTAssertFalse(PlaybackFallback.shouldRestore(
            handedOff: true, connectionHeld: false, driverChoseSince: false))
        // The driver's own pick outranks anything FLOWS wants to restore.
        XCTAssertFalse(PlaybackFallback.shouldRestore(
            handedOff: true, connectionHeld: true, driverChoseSince: true))
        // Never switch anything FLOWS didn't move in the first place.
        XCTAssertFalse(PlaybackFallback.shouldRestore(
            handedOff: false, connectionHeld: true, driverChoseSince: false))
        // The hold window is long enough to outlast a flicker.
        XCTAssertGreaterThanOrEqual(PlaybackFallback.restoreHoldSeconds, 15)
    }

    func testRestoreLineNamesTheServiceComingBack() {
        XCTAssertEqual(PlaybackFallback.restoreLine(service: "Spotify"),
                       "Signal's back — returning to Spotify.")
    }

    func testHandoffSpeaksWhatChangedAndWhy() {
        XCTAssertEqual(
            PlaybackFallback.spokenLine(for: .localLibrary),
            "Signal dropped — playing the music saved on your phone.")
        XCTAssertEqual(
            PlaybackFallback.spokenLine(for: .radio(genre: "rock")),
            "Signal dropped and there's no music saved on your phone — "
            + "trying rock radio.")
        XCTAssertEqual(
            PlaybackFallback.spokenLine(for: .nothingAvailable),
            "Signal dropped, and there's no music saved on your phone "
            + "to fall back on.")
    }

    // MARK: in-place control — the truth table every surface consults

    func testInPlaceControlTruthTableCoversEveryProvider() {
        for provider in MusicProvider.allCases {
            // Radio is FLOWS's own player — controllable everywhere with
            // no account, key, or other app. Apple Music is the other
            // always-keyless one.
            let keyless = provider == .appleMusic || provider == .radio
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

    // MARK: Spotify Web API — voice search-and-play

    func testSearchCallEncodesAndTargetsPlaylists() {
        let call = SpotifyWebAPI.searchCall(query: "classic country & hits")
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.path,
                       "/v1/search?q=classic%20country%20%26%20hits&type=playlist&limit=1")
    }

    func testParsePlaylistContextReadsTheFirstPlaylist() throws {
        let payload = """
        {"playlists":{"items":[{"uri":"spotify:playlist:37i9dQ",
          "name":"Classic Country's Best"}]}}
        """.data(using: .utf8)!
        let hit = try XCTUnwrap(SpotifyWebAPI.parsePlaylistContext(payload))
        XCTAssertEqual(hit.uri, "spotify:playlist:37i9dQ")
        XCTAssertEqual(hit.name, "Classic Country's Best")
        XCTAssertNil(SpotifyWebAPI.parsePlaylistContext(
            Data(#"{"playlists":{"items":[]}}"#.utf8)))
        XCTAssertNil(SpotifyWebAPI.parsePlaylistContext(Data("x".utf8)))
    }

    func testURLRequestCarriesAJSONBodyWhenGiven() throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["context_uri": "spotify:playlist:abc"])
        let request = try XCTUnwrap(SpotifyWebAPI.urlRequest(
            for: SpotifyWebAPI.playPauseCall(isPlaying: false),
            token: "t", body: body))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/json")
        XCTAssertEqual(request.httpBody, body)
        // No body → no content type, same as before.
        let bare = try XCTUnwrap(SpotifyWebAPI.urlRequest(
            for: SpotifyWebAPI.next, token: "t"))
        XCTAssertNil(bare.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: native Siri playback tips — verified services only

    func testSiriPlaybackTipsExistOnlyForVerifiedServices() {
        // Radio's phrase routes through FLOWS (it IS FLOWS's player).
        let verified: Set<MusicProvider> = [.radio, .appleMusic, .spotify,
                                            .youtubeMusic, .amazonMusic,
                                            .pandora, .deezer, .tidal,
                                            .iHeartRadio]
        for provider in MusicProvider.allCases {
            if verified.contains(provider) {
                XCTAssertNotNil(provider.siriPlaybackTip, provider.rawValue)
            } else {
                // No evidence = no tip — never a guessed voice command.
                XCTAssertNil(provider.siriPlaybackTip, provider.rawValue)
            }
        }
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
