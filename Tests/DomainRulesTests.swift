import XCTest

final class DomainRulesTests: XCTestCase {
    /// Two independent hosts, neither a suffix of the other, so watching and tagging can
    /// be tested without one rule accidentally covering the other.
    private let rules = DomainRules(
        watchedDomains: ["app.example.com", "staging.example.net"],
        environmentMap: ["app.example.com": "prod", "staging.example.net": "staging"]
    )

    /// The shipped default watches nothing, so a fresh install never raises a toast on a
    /// site the user didn't ask about -- and no one's hosts live in this repo.
    func testShippedDefaultWatchesNothing() {
        XCTAssertTrue(DomainRules.default.watchedDomains.isEmpty)
        XCTAssertTrue(DomainRules.default.environmentMap.isEmpty)
        XCTAssertFalse(DomainRules.default.isWatched(host: "app.example.com"))
        XCTAssertNil(DomainRules.default.environment(forHost: "app.example.com"))
    }

    // MARK: - Watching

    func testWatchesConfiguredHostsExactly() {
        XCTAssertTrue(rules.isWatched(host: "app.example.com"))
        XCTAssertTrue(rules.isWatched(host: "staging.example.net"))
    }

    func testWatchesSubdomainsOfAConfiguredHost() {
        XCTAssertTrue(rules.isWatched(host: "www.app.example.com"))
        XCTAssertTrue(rules.isWatched(host: "eu.beta.app.example.com"))
    }

    func testDoesNotWatchUnrelatedHosts() {
        XCTAssertFalse(rules.isWatched(host: "github.com"))
        XCTAssertFalse(rules.isWatched(host: "example.com"), "the parent is not the rule")
        XCTAssertFalse(rules.isWatched(host: nil))
    }

    /// The suffix check has to be anchored on a dot, or a lookalike domain registered
    /// by someone else would raise a toast and leak a URL into a ticket.
    func testSuffixMatchIsAnchoredOnADotBoundary() {
        XCTAssertFalse(rules.isWatched(host: "notapp.example.com"))
        XCTAssertFalse(rules.isWatched(host: "evil-app.example.com"))
    }

    func testHostMatchingIgnoresCaseAndTrailingDot() {
        XCTAssertTrue(rules.isWatched(host: "APP.EXAMPLE.COM"))
        XCTAssertTrue(rules.isWatched(host: "app.example.com."))
    }

    // MARK: - Environment mapping

    func testMapsHostsToEnvironmentTags() {
        XCTAssertEqual(rules.environment(forHost: "app.example.com"), "prod")
        XCTAssertEqual(rules.environment(forHost: "staging.example.net"), "staging")
    }

    func testSubdomainInheritsTheParentTag() {
        XCTAssertEqual(rules.environment(forHost: "www.app.example.com"), "prod")
    }

    func testUnmappedHostHasNoTag() {
        XCTAssertNil(rules.environment(forHost: "elsewhere.test"))
        XCTAssertNil(rules.environment(forHost: nil))
    }

    /// A more specific rule must win, so adding one doesn't require pruning the broader
    /// rule it sits under.
    func testLongestMatchingSuffixWins() {
        let nested = DomainRules(
            watchedDomains: ["example.com"],
            environmentMap: ["example.com": "prod", "staging.example.com": "staging"]
        )
        XCTAssertEqual(nested.environment(forHost: "staging.example.com"), "staging")
        XCTAssertEqual(nested.environment(forHost: "deep.staging.example.com"), "staging")
        XCTAssertEqual(nested.environment(forHost: "example.com"), "prod")
    }

    // MARK: - Normalisation

    func testNormalizeAcceptsAFullURLPastedIntoADomainField() {
        XCTAssertEqual(
            DomainRules.normalize("https://staging.example.net/sites/42?x=1"),
            "staging.example.net"
        )
    }

    func testNormalizeStripsWWWAndWhitespace() {
        XCTAssertEqual(DomainRules.normalize("  WWW.App.Example.Com  "), "app.example.com")
    }

    func testNormalizeRejectsEmptyInput() {
        XCTAssertNil(DomainRules.normalize(""))
        XCTAssertNil(DomainRules.normalize("   "))
        XCTAssertNil(DomainRules.normalize(nil))
    }

    /// A rule typed in as a URL should still match a bare host.
    func testRuleWrittenAsURLStillMatches() {
        let pasted = DomainRules(
            watchedDomains: ["https://staging.example.net/"],
            environmentMap: ["https://staging.example.net/": "staging"]
        )
        XCTAssertTrue(pasted.isWatched(host: "staging.example.net"))
        XCTAssertEqual(pasted.environment(forHost: "staging.example.net"), "staging")
    }
}
