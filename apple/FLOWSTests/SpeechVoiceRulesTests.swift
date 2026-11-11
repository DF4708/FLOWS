// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Which voice FLOWS speaks with: the owner asked for speech that does not
/// sound mechanical, with the choice in Settings.
final class SpeechVoiceRulesTests: XCTestCase {
    private func voice(
        _ id: String, _ name: String, _ language: String,
        _ quality: VoiceChoice.Quality,
        _ gender: VoiceChoice.Gender = .unspecified
    ) -> VoiceChoice {
        VoiceChoice(id: id, name: name, language: language, quality: quality, gender: gender)
    }

    /// The owner asked for a woman's voice by default.
    func testAutomaticTakesAWomansVoiceFirst() {
        let voices = [
            voice("evan", "Evan (Premium)", "en-US", .premium, .masculine),
            voice("nora", "Voice 4", "en-US", .enhanced, .feminine),
            voice("zoe", "Zoe (Premium)", "en-GB", .premium, .feminine),
            voice("sam", "Samantha", "en-US", .basic, .feminine),
        ]
        // The most natural woman's voice, ahead of a man's in the home accent.
        XCTAssertEqual(
            SpeechVoiceRules.voice(
                picked: SpeechVoiceRules.automaticID,
                among: voices, language: "en-US")?.id, "zoe")
        // A woman's Enhanced voice ahead of a man's Premium one.
        XCTAssertEqual(
            SpeechVoiceRules.voice(
                picked: SpeechVoiceRules.automaticID,
                among: Array(voices.prefix(2)),
                language: "en-US")?.id, "nora")
        // Only a man's natural voice: it still beats the machine-like ones.
        XCTAssertEqual(
            SpeechVoiceRules.voice(
                picked: SpeechVoiceRules.automaticID,
                among: [voices[0], voices[3]],
                language: "en-US")?.id, "evan")
        // The driver's own pick is never second-guessed.
        XCTAssertEqual(
            SpeechVoiceRules.voice(
                picked: "evan", among: voices,
                language: "en-US")?.id, "evan")
    }

    private var installed: [VoiceChoice] {
        [
            voice("sam", "Samantha", "en-US", .basic),
            voice("daniel", "Daniel", "en-GB", .basic),
            voice("zoe", "Zoe (Premium)", "en-US", .premium),
            voice("kate", "Kate (Enhanced)", "en-GB", .enhanced),
            voice("ava", "Ava (Premium)", "en-US", .premium),
            voice("serena", "Serena (Premium)", "en-GB", .premium),
            voice("amelie", "Amélie", "fr-CA", .premium),
        ]
    }

    func testSpokenLanguageIsTheDevicesEnglishElseAmerican() {
        XCTAssertEqual(SpeechVoiceRules.spokenLanguage(device: "en-GB"), "en-GB")
        XCTAssertEqual(SpeechVoiceRules.spokenLanguage(device: "en-US"), "en-US")
        XCTAssertEqual(SpeechVoiceRules.spokenLanguage(device: "fr-FR"), "en-US")
        XCTAssertEqual(SpeechVoiceRules.spokenLanguage(device: ""), "en-US")
    }

    func testChoicesAreEnglishOnlyMostNaturalFirstOwnAccentAhead() {
        let ids = SpeechVoiceRules.choices(among: installed, language: "en-US").map(\.id)
        XCTAssertEqual(ids, ["ava", "zoe", "serena", "kate", "sam", "daniel"])
        let british = SpeechVoiceRules.choices(among: installed, language: "en-GB").map(\.id)
        XCTAssertEqual(british, ["serena", "ava", "zoe", "kate", "daniel", "sam"])
    }

    func testAutomaticTakesTheMostNaturalVoice() {
        let pick = SpeechVoiceRules.voice(
            picked: SpeechVoiceRules.automaticID,
            among: installed, language: "en-US")
        XCTAssertEqual(pick?.id, "ava")
    }

    /// With only the voices the device ships with, FLOWS leaves the choice
    /// to the system, exactly as before the setting existed.
    func testAutomaticLeavesTheSystemDefaultWhenOnlyBasicVoicesAreInstalled() {
        let basic = installed.filter { $0.quality == .basic }
        XCTAssertNil(
            SpeechVoiceRules.voice(
                picked: SpeechVoiceRules.automaticID,
                among: basic, language: "en-US"))
        XCTAssertNil(
            SpeechVoiceRules.voice(
                picked: SpeechVoiceRules.automaticID,
                among: [], language: "en-US"))
    }

    func testThePickWinsEvenOverAMoreNaturalVoice() {
        let pick = SpeechVoiceRules.voice(picked: "daniel", among: installed, language: "en-US")
        XCTAssertEqual(pick?.id, "daniel")
    }

    func testAPickThatWasRemovedFallsBackToTheMostNatural() {
        let pick = SpeechVoiceRules.voice(picked: "gone", among: installed, language: "en-US")
        XCTAssertEqual(pick?.id, "ava")
        let basic = installed.filter { $0.quality == .basic }
        XCTAssertNil(SpeechVoiceRules.voice(picked: "gone", among: basic, language: "en-US"))
    }

    /// FLOWS's lines are English: a French voice would mangle them.
    func testAPickInAnotherLanguageIsNotUsed() {
        let pick = SpeechVoiceRules.voice(picked: "amelie", among: installed, language: "en-US")
        XCTAssertEqual(pick?.id, "ava")
    }

    func testLabelNamesTheVoiceItsAccentAndItsQualityOnce() {
        XCTAssertEqual(
            SpeechVoiceRules.label(voice("ava", "Ava (Premium)", "en-US", .premium), region: "US"),
            "Ava · US · Premium")
        XCTAssertEqual(
            SpeechVoiceRules.label(
                voice("kate", "Kate (Enhanced)", "en-GB", .enhanced),
                region: "UK"),
            "Kate · UK · Enhanced")
        XCTAssertEqual(
            SpeechVoiceRules.label(voice("sam", "Samantha", "en-US", .basic), region: "US"),
            "Samantha · US")
        XCTAssertEqual(
            SpeechVoiceRules.label(voice("x", "Nora", "en", .enhanced), region: ""),
            "Nora · Enhanced")
    }

    func testRegionNames() {
        XCTAssertEqual(SpeechVoiceRules.region(of: "en-US"), "US")
        XCTAssertEqual(SpeechVoiceRules.region(of: "en-GB"), "UK")
        XCTAssertEqual(SpeechVoiceRules.region(of: "en-AU"), "Australia")
        XCTAssertEqual(SpeechVoiceRules.region(of: "en-SG"), "SG")
        XCTAssertEqual(SpeechVoiceRules.region(of: "en"), "")
    }

    /// The middle of the slider is the rate FLOWS always spoke at, and a
    /// saved step from outside the slider cannot index past its ends.
    func testSpeedStepsKeepTheOldRateInTheMiddleAndClamp() {
        XCTAssertEqual(SpeechVoiceRules.rate(step: SpeechVoiceRules.normalSpeedStep), 0.5)
        XCTAssertEqual(SpeechVoiceRules.rate(step: 0), 0.40)
        XCTAssertEqual(SpeechVoiceRules.rate(step: 4), 0.60)
        XCTAssertEqual(SpeechVoiceRules.rate(step: -3), 0.40)
        XCTAssertEqual(SpeechVoiceRules.rate(step: 99), 0.60)
        XCTAssertEqual(SpeechVoiceRules.speeds, SpeechVoiceRules.speeds.sorted())
    }

    private func lost(speaking: Bool = false, age: Double, picked: Bool, began: Bool) -> Bool {
        SpeechVoiceRules.lineIsLost(
            speaking: speaking, age: .seconds(age), pickedVoice: picked, began: began,
            grace: .seconds(2), loadGrace: .seconds(6))
    }

    /// The system's default voice is judged exactly as before.
    func testDefaultVoiceLineIsLostAfterTheShortGrace() {
        XCTAssertFalse(lost(age: 1.9, picked: false, began: false))
        XCTAssertTrue(lost(age: 2.1, picked: false, began: false))
        XCTAssertTrue(lost(age: 2.1, picked: false, began: true))
    }

    /// A natural voice is loaded before its first word: a line still loading
    /// must not be thrown away and the next one started over it.
    func testPickedVoiceLineGetsTimeToLoad() {
        XCTAssertFalse(lost(age: 2.1, picked: true, began: false))
        XCTAssertFalse(lost(age: 5.9, picked: true, began: false))
        XCTAssertTrue(lost(age: 6.1, picked: true, began: false))
    }

    /// Once it has begun, a quiet synthesizer means the report was lost.
    func testPickedVoiceLineThatBeganIsJudgedByTheShortGrace() {
        XCTAssertTrue(lost(age: 2.1, picked: true, began: true))
        XCTAssertFalse(lost(age: 1.0, picked: true, began: true))
    }

    func testALineBeingSpokenIsNeverLost() {
        XCTAssertFalse(lost(speaking: true, age: 60, picked: false, began: true))
        XCTAssertFalse(lost(speaking: true, age: 60, picked: true, began: false))
    }
}
