import XCTest

final class JiraKeyTests: XCTestCase {
    func testBareKeyPassesThrough() {
        XCTAssertEqual(JiraKey.normalize("BUG-412"), "BUG-412")
    }

    func testLowercaseKeyIsUppercased() {
        XCTAssertEqual(JiraKey.normalize("bug-412"), "BUG-412")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(JiraKey.normalize("  BUG-412\n"), "BUG-412")
    }

    /// Copying from the address bar is at least as likely as copying the key itself.
    func testPastedBrowseURLYieldsTheKey() {
        XCTAssertEqual(
            JiraKey.normalize("https://example.atlassian.net/browse/BUG-412"),
            "BUG-412"
        )
    }

    func testPastedBrowseURLWithQueryYieldsTheKey() {
        XCTAssertEqual(
            JiraKey.normalize("https://example.atlassian.net/browse/BUG-412?focusedCommentId=99"),
            "BUG-412"
        )
    }

    func testKeyInsideAShortPhraseIsFound() {
        XCTAssertEqual(JiraKey.normalize("BUG-412 is fixed"), "BUG-412")
        XCTAssertEqual(JiraKey.normalize("filed as bug-7"), "BUG-7")
    }

    func testProjectKeysWithDigitsAndUnderscoresAreAccepted() {
        XCTAssertEqual(JiraKey.normalize("BUG2-13"), "BUG2-13")
        XCTAssertEqual(JiraKey.normalize("BUG_X-13"), "BUG_X-13")
    }

    // MARK: - Rejections

    /// A near-miss must return nil rather than a plausible-looking key, because the
    /// result becomes a link the user will click and find broken.
    func testTrailingCharactersAreRejectedRatherThanTruncated() {
        XCTAssertNil(JiraKey.normalize("NOTAKEY-1X"))
        XCTAssertNil(JiraKey.normalize("BUG-412b"))
    }

    func testMissingNumberIsRejected() {
        XCTAssertNil(JiraKey.normalize("BUG-"))
        XCTAssertNil(JiraKey.normalize("BUG"))
    }

    func testKeyMustStartWithALetter() {
        XCTAssertNil(JiraKey.normalize("1BUG-412"))
        XCTAssertNil(JiraKey.normalize("-412"))
    }

    func testEmptyAndNilAreRejected() {
        XCTAssertNil(JiraKey.normalize(nil))
        XCTAssertNil(JiraKey.normalize(""))
        XCTAssertNil(JiraKey.normalize("   "))
    }

    func testProseWithoutAKeyIsRejected() {
        XCTAssertNil(JiraKey.normalize("the canvas doesn't update"))
    }

    // MARK: - Links

    func testBrowseURLIsBuiltFromSiteAndKey() {
        XCTAssertEqual(
            JiraKey.browseURL(site: "example", key: "BUG-412")?.absoluteString,
            "https://example.atlassian.net/browse/BUG-412"
        )
    }

    func testBrowseURLNeedsASite() {
        XCTAssertNil(JiraKey.browseURL(site: "", key: "BUG-412"))
    }
}
