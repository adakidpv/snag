import XCTest

final class AppSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings.Stored {
        try JSONDecoder().decode(AppSettings.Stored.self, from: Data(json.utf8))
    }

    func testRoundTripsAFullyPopulatedBlob() throws {
        var original = AppSettings.Stored()
        original.model = "claude-opus-5-5"
        original.toastEnabled = false
        original.boards = [Board(name: "Web", site: "example", projectID: "10001", issueTypeID: "10004")]
        original.lastUsedBoardID = original.boards[0].id

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.Stored.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    /// The reason the custom decoder exists: a blob written by an older version is
    /// missing keys a newer version knows about. The synthesized decoder would throw,
    /// and the app would fall back to defaults -- quietly discarding configured boards.
    func testBlobMissingNewerKeysKeepsWhatItHasAndDefaultsTheRest() throws {
        let stored = try decode(#"{"model":"claude-haiku-5-5"}"#)

        XCTAssertEqual(stored.model, "claude-haiku-5-5")
        XCTAssertEqual(stored.domainRules, .default)
        XCTAssertTrue(stored.toastEnabled)
        XCTAssertTrue(stored.boards.isEmpty)
        XCTAssertNil(stored.lastUsedBoardID)
    }

    func testBoardsSurviveABlobThatPredatesOtherSettings() throws {
        let json = #"""
        {"boards":[{"id":"8C6E8A3E-5A1F-4C7B-9E2A-1D4F6B8C0A21","name":"Web",
        "site":"example","projectID":"10001","issueTypeID":"10004",
        "defaultLabels":["web"],"mode":"restAPI","accountEmail":"qa@example.com"}]}
        """#
        let stored = try decode(json)

        XCTAssertEqual(stored.boards.count, 1)
        XCTAssertEqual(stored.boards.first?.name, "Web")
        XCTAssertEqual(stored.boards.first?.defaultLabels, ["web"])
        XCTAssertEqual(stored.model, "claude-sonnet-5-5")
    }

    // MARK: - Board migration

    /// The board itself decodes field by field for the same reason the blob does: a
    /// board written before the drafting settings existed has neither key, and a throw
    /// there would take every board on the machine with it.
    func testBoardWrittenBeforeTheDraftingSettingsKeepsItsJiraConfiguration() throws {
        let json = #"""
        {"boards":[{"id":"8C6E8A3E-5A1F-4C7B-9E2A-1D4F6B8C0A21","name":"Web",
        "site":"example","projectID":"10001","issueTypeID":"10004",
        "defaultLabels":["web"],"mode":"restAPI","accountEmail":"qa@example.com"}]}
        """#
        let board = try XCTUnwrap(try decode(json).boards.first)

        XCTAssertEqual(board.site, "example", "the board must not be reset")
        XCTAssertEqual(board.id, UUID(uuidString: "8C6E8A3E-5A1F-4C7B-9E2A-1D4F6B8C0A21"),
                       "a new id would orphan the board's Keychain token")
        // Nothing to seed from: a board written before these keys existed loads
        // product-neutral rather than inheriting a description of someone else's product.
        XCTAssertEqual(board.productContext, "")
        XCTAssertEqual(board.areas, [])
    }

    /// A configured empty list and a missing key are different things: an empty list is
    /// a decision, and seeding over it would hand the user back a taxonomy they removed.
    func testExplicitlyEmptyDraftingSettingsAreKeptRatherThanReseeded() throws {
        let json = #"""
        {"boards":[{"id":"8C6E8A3E-5A1F-4C7B-9E2A-1D4F6B8C0A21","name":"Ledger",
        "site":"ledger","projectID":"1","issueTypeID":"2","defaultLabels":[],
        "mode":"restAPI","accountEmail":"a@b.com","productContext":"","areas":[]}]}
        """#
        let board = try XCTUnwrap(try decode(json).boards.first)

        XCTAssertEqual(board.productContext, "")
        XCTAssertTrue(board.areas.isEmpty)
    }

    func testBoardWithAGarbledFieldKeepsTheRestInsteadOfBeingDropped() throws {
        let json = #"""
        {"boards":[{"id":"8C6E8A3E-5A1F-4C7B-9E2A-1D4F6B8C0A21","name":"Ledger",
        "site":"ledger","projectID":"1","issueTypeID":"2","defaultLabels":[],
        "mode":"restAPI","accountEmail":"a@b.com","areas":"checkout, search"}]}
        """#
        let board = try XCTUnwrap(try decode(json).boards.first)

        XCTAssertEqual(board.site, "ledger")
        XCTAssertTrue(board.areas.isEmpty, "falls back rather than throwing")
    }

    func testBoardRoundTripsTheDraftingSettings() throws {
        var original = AppSettings.Stored()
        var board = Board(name: "Ledger", site: "ledger")
        board.productContext = "You write bug tickets for Ledger, an accounting app."
        board.areas = ["invoices", "reports"]
        original.boards = [board]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.Stored.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.boards.first?.areas, ["invoices", "reports"])
    }

    func testNormalizedAreasTrimsBlanksAndDuplicatesButKeepsOrder() {
        var board = Board()
        board.areas = [" checkout ", "", "search", "checkout", "  ", "admin"]

        XCTAssertEqual(board.normalizedAreas, ["checkout", "search", "admin"])
    }

    /// A single unreadable field shouldn't cost the whole blob either.
    func testGarbledFieldFallsBackWithoutLosingTheOthers() throws {
        let stored = try decode(#"{"model":"claude-opus-5-5","toastEnabled":"yes please"}"#)

        XCTAssertEqual(stored.model, "claude-opus-5-5")
        XCTAssertTrue(stored.toastEnabled, "should fall back to the default, not throw")
    }

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), AppSettings.Stored())
    }

    // MARK: - Persistence

    /// An isolated defaults domain, so these never touch the real app's settings.
    private func isolatedDefaults() -> UserDefaults {
        let suite = "SnagSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testChangesSurviveANewInstance() {
        let defaults = isolatedDefaults()

        let first = AppSettings(defaults: defaults)
        first.model = "claude-opus-5-5"
        first.toastEnabled = false
        first.domainRules = DomainRules(
            watchedDomains: ["app.example.com"],
            environmentMap: ["app.example.com": "prod"]
        )

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.model, "claude-opus-5-5")
        XCTAssertFalse(second.toastEnabled)
        XCTAssertEqual(second.domainRules.watchedDomains, ["app.example.com"])
    }

    /// A fresh install watches nothing. Shipping a domain list would raise toasts on
    /// sites the user never asked about -- and would put someone's hosts in the repo.
    func testDefaultsWatchNothingUntilConfigured() {
        let settings = AppSettings(defaults: isolatedDefaults())

        XCTAssertEqual(settings.model, "claude-sonnet-5-5")
        XCTAssertTrue(settings.toastEnabled)
        XCTAssertTrue(settings.domainRules.watchedDomains.isEmpty)
        XCTAssertTrue(settings.domainRules.environmentMap.isEmpty)
        XCTAssertNil(settings.domainRules.environment(forHost: "app.example.com"))
    }

    func testBlankModelFallsBackToTheDefault() {
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.model = "   "
        XCTAssertEqual(settings.model, AppSettings.defaultModel)
    }

    // MARK: - Boards

    func testUpsertAddsThenUpdatesInPlace() {
        let settings = AppSettings(defaults: isolatedDefaults())
        var board = Board(name: "Web", site: "example")

        settings.upsert(board: board)
        XCTAssertEqual(settings.boards.count, 1)

        board.name = "Web renamed"
        settings.upsert(board: board)
        XCTAssertEqual(settings.boards.count, 1, "same id should update, not append")
        XCTAssertEqual(settings.boards.first?.name, "Web renamed")
    }

    func testPreferredBoardPrefersTheLastUsed() {
        let settings = AppSettings(defaults: isolatedDefaults())
        let first = Board(name: "First", site: "a")
        let second = Board(name: "Second", site: "b")
        settings.upsert(board: first)
        settings.upsert(board: second)

        XCTAssertEqual(settings.preferredBoard?.id, first.id, "falls back to the first")

        settings.lastUsedBoardID = second.id
        XCTAssertEqual(settings.preferredBoard?.id, second.id)
    }

    /// A stale last-used id (its board was deleted) must not leave the Report panel
    /// with no board selected.
    func testPreferredBoardIgnoresAStaleLastUsedID() {
        let settings = AppSettings(defaults: isolatedDefaults())
        let board = Board(name: "Only", site: "a")
        settings.upsert(board: board)
        settings.lastUsedBoardID = UUID()

        XCTAssertEqual(settings.preferredBoard?.id, board.id)
    }

    func testRemovingABoardClearsItAsLastUsed() {
        let settings = AppSettings(defaults: isolatedDefaults())
        let board = Board(name: "Only", site: "a")
        settings.upsert(board: board)
        settings.lastUsedBoardID = board.id

        settings.removeBoard(id: board.id)

        XCTAssertTrue(settings.boards.isEmpty)
        XCTAssertNil(settings.lastUsedBoardID)
        XCTAssertNil(settings.preferredBoard)
    }

    // MARK: - Board validation

    func testConfigurationProblemNamesTheFirstMissingField() {
        var board = Board()
        XCTAssertEqual(board.configurationProblem, "Jira site is not set")

        board.site = "example"
        XCTAssertEqual(board.configurationProblem, "Project ID is not set")

        board.projectID = "10001"
        XCTAssertEqual(board.configurationProblem, "Issue type ID is not set")

        board.issueTypeID = "10004"
        XCTAssertEqual(board.configurationProblem, "Atlassian account email is not set")

        board.accountEmail = "qa@example.com"
        XCTAssertNil(board.configurationProblem)
    }

    /// The URL fallback needs no account email, so it mustn't be demanded there.
    func testPrefilledURLModeDoesNotRequireAnEmail() {
        var board = Board(mode: .prefilledURL)
        board.site = "example"
        board.projectID = "10001"
        board.issueTypeID = "10004"
        XCTAssertNil(board.configurationProblem)
    }
}
