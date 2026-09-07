//
//  SBLastFMTests.swift
//  SubmarinerTests
//
//  Unit tests for the pure logic in SBLastFM: the scrobble-timing rule,
//  Last.fm request signing, and API response parsing. These are exercised
//  directly (no network, no Keychain, no Core Data) via internal static
//  helpers exposed through @testable import.
//

import XCTest
@testable import Submariner

final class SBLastFMTests: XCTestCase {
    // MARK: - shouldScrobble (Last.fm scrobbling rule)
    //
    // Rule: a track scrobbles once it has played for at least half its
    // duration, or 4 minutes (240s), whichever comes first, and only if
    // the track itself is longer than 30 seconds.

    func testShouldScrobble_trackTooShort_isNeverTrue() {
        // A 20s track never qualifies, no matter how much of it played.
        XCTAssertFalse(SBLastFM.shouldScrobble(elapsed: 20, duration: 20))
    }

    func testShouldScrobble_trackAtThirtySecondBoundary_isFalse() {
        // Must be longer than 30s, not merely 30s.
        XCTAssertFalse(SBLastFM.shouldScrobble(elapsed: 30, duration: 30))
    }

    func testShouldScrobble_beforeHalfDuration_isFalse() {
        // 100s track, played 49s: below the 50s halfway point.
        XCTAssertFalse(SBLastFM.shouldScrobble(elapsed: 49, duration: 100))
    }

    func testShouldScrobble_atHalfDuration_isTrue() {
        // 100s track, played 50s: exactly at the halfway point.
        XCTAssertTrue(SBLastFM.shouldScrobble(elapsed: 50, duration: 100))
    }

    func testShouldScrobble_longTrackBeforeFourMinuteCap_isFalse() {
        // 20 minute track, played 239s: half (600s) not reached, cap (240s) not reached either.
        XCTAssertFalse(SBLastFM.shouldScrobble(elapsed: 239, duration: 1200))
    }

    func testShouldScrobble_longTrackAtFourMinuteCap_isTrue() {
        // 20 minute track, played 240s: the 4-minute cap applies before the halfway point.
        XCTAssertTrue(SBLastFM.shouldScrobble(elapsed: 240, duration: 1200))
    }

    // MARK: - parseResponseCount

    func testParseResponseCount_topLevelStringValue() {
        let object: [String: Any] = ["accepted": "3"]
        XCTAssertEqual(SBLastFM.parseResponseCount(object, key: "accepted"), 3)
    }

    func testParseResponseCount_topLevelIntValue() {
        let object: [String: Any] = ["accepted": 3]
        XCTAssertEqual(SBLastFM.parseResponseCount(object, key: "accepted"), 3)
    }

    func testParseResponseCount_nestedUnderAttr() {
        // Last.fm's batch scrobble response reports counts under "@attr".
        let object: [String: Any] = ["@attr": ["accepted": "12", "ignored": "1"]]
        XCTAssertEqual(SBLastFM.parseResponseCount(object, key: "accepted"), 12)
        XCTAssertEqual(SBLastFM.parseResponseCount(object, key: "ignored"), 1)
    }

    func testParseResponseCount_missingKey_isZero() {
        let object: [String: Any] = [:]
        XCTAssertEqual(SBLastFM.parseResponseCount(object, key: "accepted"), 0)
    }

    // MARK: - formEncode

    func testFormEncode_sortsKeysAlphabetically() {
        let encoded = SBLastFM.formEncode(["b": "2", "a": "1"])
        XCTAssertEqual(encoded, "a=1&b=2")
    }

    func testFormEncode_percentEncodesReservedCharacters() {
        // A single key whose value itself contains "&" and " " must not be
        // mistaken for an extra parameter or a literal space once encoded.
        let encoded = SBLastFM.formEncode(["q": "a b&c"])
        XCTAssertEqual(encoded.components(separatedBy: "&").count, 1, "value's & must be percent-encoded, not a param separator")
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertTrue(encoded.hasPrefix("q="))
    }

    // MARK: - md5Hex (RFC 1321 test vectors)

    func testMd5Hex_emptyString() {
        XCTAssertEqual(SBLastFM.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testMd5Hex_abc() {
        XCTAssertEqual(SBLastFM.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    // MARK: - apiSignature (Last.fm request signing)
    //
    // Signature = md5(sorted "key" + "value" pairs concatenated, then the
    // shared secret appended), computed *before* adding format/api_sig
    // themselves. Verified against a hand-computed vector.

    func testApiSignature_matchesKnownVector() {
        let parameters = ["method": "auth.getSession", "api_key": "abc123", "token": "tok"]
        let signature = SBLastFM.apiSignature(parameters: parameters, secret: "secret")
        // Expected base string: api_key + abc123 + method + auth.getSession + token + tok + secret
        let expectedBase = "api_keyabc123methodauth.getSessiontokentoksecret"
        XCTAssertEqual(signature, SBLastFM.md5Hex(expectedBase))
    }

    func testApiSignature_excludesFormatParameter() {
        // "format" must never be part of the signed payload per Last.fm's API rules,
        // so adding it must not change the resulting signature.
        let withoutFormat = SBLastFM.apiSignature(parameters: ["method": "auth.getToken"], secret: "s")
        let withFormat = SBLastFM.apiSignature(parameters: ["method": "auth.getToken", "format": "json"], secret: "s")
        XCTAssertEqual(withoutFormat, withFormat, "format must be excluded from the signed payload")
    }
}
