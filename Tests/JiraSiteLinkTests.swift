import XCTest

/// The parser is the first thing a new user touches, and the only part of onboarding
/// that runs before any credentials exist. Every form here is one someone can actually
/// have in their address bar.
final class JiraSiteLinkTests: XCTestCase {
    private func parse(_ raw: String?) throws -> JiraSiteLink {
        try JiraSiteLink.parse(raw)
    }

    // MARK: - Links that name a project

    func testReadsSiteAndProjectFromABrowseURL() throws {
        let link = try parse("https://acme.atlassian.net/browse/BUG-412")
        XCTAssertEqual(link.site, "acme")
        XCTAssertEqual(link.projectKey, "BUG")
    }

    func testReadsProjectFromTheSoftwareBoardURL() throws {
        let link = try parse("https://acme.atlassian.net/jira/software/projects/ABC/boards/1")
        XCTAssertEqual(link, JiraSiteLink(site: "acme", projectKey: "ABC"))
    }

    /// Classic projects sit under an extra `c` segment.
    func testReadsProjectFromTheClassicSoftwareBoardURL() throws {
        let link = try parse("https://acme.atlassian.net/jira/software/c/projects/ABC/boards/1")
        XCTAssertEqual(link.projectKey, "ABC")
    }

    func testReadsProjectFromABusinessProjectURL() throws {
        XCTAssertEqual(try parse("https://acme.atlassian.net/jira/core/projects/OPS/board").projectKey, "OPS")
    }

    func testReadsProjectFromTheIssuesListURL() throws {
        XCTAssertEqual(try parse("https://acme.atlassian.net/projects/ABC/issues").projectKey, "ABC")
    }

    func testReadsProjectFromARapidBoardQueryParameter() throws {
        let link = try parse("https://acme.atlassian.net/secure/RapidBoard.jspa?rapidView=1&projectKey=ABC")
        XCTAssertEqual(link.projectKey, "ABC")
    }

    /// A board link that names no project in its path still carries the selected issue,
    /// and an issue key names its project.
    func testReadsProjectFromASelectedIssueQueryParameter() throws {
        let link = try parse("https://acme.atlassian.net/secure/RapidBoard.jspa?rapidView=1&selectedIssue=ABC-9")
        XCTAssertEqual(link.projectKey, "ABC")
    }

    func testIgnoresUnrelatedQueryParameters() throws {
        let link = try parse("https://acme.atlassian.net/browse/BUG-412?focusedCommentId=99")
        XCTAssertEqual(link, JiraSiteLink(site: "acme", projectKey: "BUG"))
    }

    func testAcceptsKeysWithDigitsAndUnderscores() throws {
        XCTAssertEqual(try parse("https://acme.atlassian.net/projects/AB2/issues").projectKey, "AB2")
        XCTAssertEqual(try parse("https://acme.atlassian.net/projects/A_B/issues").projectKey, "A_B")
    }

    func testUppercasesALowercasedKey() throws {
        XCTAssertEqual(try parse("https://acme.atlassian.net/browse/bug-412").projectKey, "BUG")
    }

    // MARK: - Links that name only the site

    func testAcceptsABareHostWithNoScheme() throws {
        XCTAssertEqual(try parse("acme.atlassian.net"), JiraSiteLink(site: "acme", projectKey: nil))
    }

    func testAcceptsTheSiteRootWithATrailingSlash() throws {
        XCTAssertEqual(try parse("https://acme.atlassian.net/"), JiraSiteLink(site: "acme", projectKey: nil))
    }

    func testLowercasesTheSiteAndStripsWWWAndTrailingDot() throws {
        XCTAssertEqual(try parse("https://WWW.ACME.ATLASSIAN.NET./").site, "acme")
    }

    /// Pasting from a browser routinely brings whitespace or a newline with it.
    func testTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(try parse("  https://acme.atlassian.net/browse/BUG-1\n").projectKey, "BUG")
    }

    /// The site is still usable even when the project can't be read, so the parser must
    /// return it rather than failing the whole paste.
    func testKeepsTheSiteWhenTheProjectSegmentIsntAKey() throws {
        XCTAssertEqual(try parse("https://acme.atlassian.net/projects/123/issues"),
                       JiraSiteLink(site: "acme", projectKey: nil))
    }

    func testRejectsAnIssueKeyFragmentThatIsntAWholeKey() throws {
        XCTAssertNil(try parse("https://acme.atlassian.net/browse/NOTAKEY-1X").projectKey)
    }

    func testFindsNoProjectInADashboardURL() throws {
        XCTAssertNil(try parse("https://acme.atlassian.net/jira/dashboards/10000").projectKey)
    }

    // MARK: - Rejections

    private func failure(_ raw: String?) -> JiraSiteLink.Failure? {
        do {
            _ = try JiraSiteLink.parse(raw)
            return nil
        } catch let failure as JiraSiteLink.Failure {
            return failure
        } catch {
            return nil
        }
    }

    func testRejectsEmptyInput() {
        XCTAssertEqual(failure(nil), .empty)
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   \n "), .empty)
    }

    /// Server and Data Center aren't a missing setting, they're out of scope -- the whole
    /// client is built on `{site}.atlassian.net`.
    func testRejectsSomethingThatIsntAnAddressAtAll() {
        XCTAssertEqual(failure("not a url at all"), .unreadable)
    }

    func testRejectsANonCloudJiraHost() {
        XCTAssertEqual(failure("https://jira.example.com/browse/BUG-1"), .notJiraCloud(host: "jira.example.com"))
    }

    func testRejectsALookalikeHost() {
        XCTAssertEqual(
            failure("https://acme.atlassian.net.example.com/browse/BUG-1"),
            .notJiraCloud(host: "acme.atlassian.net.example.com"),
            "the suffix check must be anchored, or a lookalike gets treated as a tenant"
        )
    }

    func testRejectsTheBareAtlassianDomain() {
        XCTAssertEqual(failure("atlassian.net"), .noTenant(host: "atlassian.net"))
    }

    func testRejectsAMultiLabelTenant() {
        XCTAssertEqual(failure("https://a.b.atlassian.net"), .noTenant(host: "a.b.atlassian.net"))
    }

    func testEveryFailureExplainsItself() {
        for failure: JiraSiteLink.Failure in [
            .empty, .unreadable, .notJiraCloud(host: "jira.example.com"), .noTenant(host: "atlassian.net"),
        ] {
            XCTAssertFalse(
                (failure.errorDescription ?? "").isEmpty,
                "a failure with no message leaves the user stuck at the first field"
            )
        }
    }
}
