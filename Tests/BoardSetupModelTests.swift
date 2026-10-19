import XCTest

/// Drives the whole setup flow offline. The promise being tested is that a user who
/// pastes a link and a token ends up with a board carrying both numeric ids, without
/// ever having seen one.
@MainActor
final class BoardSetupModelTests: XCTestCase {
    private static let myselfJSON = #"""
    {"accountId":"5b10a2","displayName":"Akhil Anil","emailAddress":"qa@example.com"}
    """#

    private static let projectJSON = #"""
    {"id":"10001","key":"ABC","name":"Acme Web","issueTypes":[
      {"id":"10004","name":"Bug","subtask":false},
      {"id":"10002","name":"Task","subtask":false}
    ]}
    """#

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func model(link: String = "https://acme.atlassian.net/browse/ABC-412") -> BoardSetupModel {
        let model = BoardSetupModel()
        model.session = StubURLProtocol.session()
        model.pastedLink = link
        model.email = "qa@example.com"
        model.token = "token123"
        return model
    }

    // MARK: - Step 1

    func testAGoodLinkAdvancesToConnect() {
        let model = model()
        model.submitLink()

        XCTAssertEqual(model.step, .connect)
        XCTAssertEqual(model.link?.site, "acme")
        XCTAssertEqual(model.link?.projectKey, "ABC")
        XCTAssertNil(model.errorMessage)
    }

    func testABadLinkStaysPutAndExplainsItself() {
        let model = model(link: "https://jira.example.com/browse/ABC-1")
        model.submitLink()

        XCTAssertEqual(model.step, .link, "the user can't be moved past a step that failed")
        XCTAssertNil(model.link)
        XCTAssertTrue(model.errorMessage?.contains("Jira Cloud") == true, "got \(model.errorMessage ?? "nil")")
    }

    // MARK: - Step 2 into 3

    func testConnectingPrefillsTheEmailAndResolvesTheProjectInOneGo() async {
        StubURLProtocol.enqueue(.json(Self.myselfJSON), .json(Self.projectJSON))

        let model = model()
        model.email = "typed-by-hand@example.com"
        model.submitLink()
        await model.connect()

        XCTAssertEqual(model.step, .project)
        XCTAssertEqual(model.account?.displayName, "Akhil Anil")
        XCTAssertEqual(model.email, "qa@example.com", "Jira's own answer wins over what was typed")
        XCTAssertEqual(model.project?.id, "10001")
        XCTAssertEqual(model.issueTypeID, "10004", "Bug is preselected")
        XCTAssertEqual(model.name, "Acme Web", "the board is named after the project")
        XCTAssertNil(model.errorMessage)
    }

    /// A profile that hides its email must not blank what the user typed.
    func testAHiddenEmailLeavesTheTypedOneAlone() async {
        StubURLProtocol.enqueue(
            .json(#"{"accountId":"5b10a2","displayName":"Akhil Anil"}"#),
            .json(Self.projectJSON)
        )
        let model = model()
        model.email = "typed-by-hand@example.com"
        model.submitLink()
        await model.connect()

        XCTAssertEqual(model.email, "typed-by-hand@example.com")
    }

    func testALinkWithNoProjectListsWhatTheAccountCanSee() async {
        StubURLProtocol.enqueue(
            .json(Self.myselfJSON),
            .json(#"""
            {"values":[
              {"id":"1","key":"AAA","name":"Alpha","issueTypes":[]},
              {"id":"2","key":"BBB","name":"Beta","issueTypes":[]}
            ]}
            """#)
        )

        let model = model(link: "acme.atlassian.net")
        model.submitLink()
        await model.connect()

        XCTAssertEqual(model.step, .project)
        XCTAssertNil(model.project, "nothing is chosen for the user")
        XCTAssertEqual(model.projects.map(\.key), ["AAA", "BBB"])
    }

    func testRejectedCredentialsKeepTheUserOnConnect() async {
        StubURLProtocol.enqueue(.json("{}", status: 401))

        let model = model()
        model.submitLink()
        await model.connect()

        XCTAssertEqual(model.step, .connect)
        XCTAssertNil(model.account)
        XCTAssertTrue(model.errorMessage?.contains("API token") == true, "got \(model.errorMessage ?? "nil")")
    }

    // MARK: - Step 3

    func testSelectingAProjectPicksBugAndNamesTheBoard() {
        let model = model()
        let project = JiraDiscovery.Project(
            id: "77", key: "OPS", name: "Operations",
            issueTypes: [
                .init(id: "1", name: "Bug sub-task", isSubtask: true),
                .init(id: "2", name: "Bug", isSubtask: false),
            ]
        )
        model.select(project)

        XCTAssertEqual(model.issueTypeID, "2", "a subtask type can't be created on its own")
        XCTAssertEqual(model.name, "Operations")
        XCTAssertTrue(model.canLeaveProjectStep)
    }

    func testTheProjectStepCannotBeLeftEmpty() {
        let model = model()
        XCTAssertFalse(model.canLeaveProjectStep)
    }

    // MARK: - Step 4

    private func readyModel() async -> BoardSetupModel {
        StubURLProtocol.enqueue(.json(Self.myselfJSON), .json(Self.projectJSON))
        let model = model()
        model.submitLink()
        await model.connect()
        return model
    }

    func testReviewNamesTheRequiredFieldsSnagCannotFill() async {
        let model = await readyModel()
        StubURLProtocol.enqueue(.json(#"""
        {"values":[
          {"fieldId":"summary","name":"Summary","required":true,"hasDefaultValue":false},
          {"fieldId":"customfield_10050","name":"Severity","required":true,"hasDefaultValue":false}
        ]}
        """#))
        await model.reviewAfterCheckingFields()

        XCTAssertEqual(model.step, .review)
        XCTAssertEqual(model.unfillableFields.map(\.name), ["Severity"])
        XCTAssertNil(model.fieldCheckNote)
    }

    /// The field check is a warning about Jira's configuration, not a step that has to
    /// succeed -- failing it must not trap the user one click from the end.
    func testAFailedFieldCheckIsANoteRatherThanABlocker() async {
        let model = await readyModel()
        StubURLProtocol.enqueue(.json(#"{"errorMessages":["boom"]}"#, status: 500))
        await model.reviewAfterCheckingFields()

        XCTAssertEqual(model.step, .review, "setup still reaches the end")
        XCTAssertTrue(model.unfillableFields.isEmpty)
        XCTAssertNotNil(model.fieldCheckNote)
        XCTAssertNotNil(model.finishedBoard())
    }

    func testFinishedBoardCarriesTheIdsTheUserNeverSaw() async {
        let model = await readyModel()
        let board = try? XCTUnwrap(model.finishedBoard())

        XCTAssertEqual(board?.site, "acme")
        XCTAssertEqual(board?.projectID, "10001")
        XCTAssertEqual(board?.issueTypeID, "10004")
        XCTAssertEqual(board?.accountEmail, "qa@example.com")
        XCTAssertEqual(board?.mode, .restAPI)
        XCTAssertEqual(board?.productContext, "", "setup seeds no product description")
        XCTAssertEqual(board?.areas, [])
    }

    func testThereIsNoBoardUntilAProjectIsResolved() {
        let model = model()
        model.submitLink()
        XCTAssertNil(model.finishedBoard())
    }

    // MARK: - Domains and escape hatches

    func testTheWatchedDomainIsNormalisedLikeTheDomainsTab() async {
        let model = await readyModel()

        model.watchDomain = "  https://WWW.App.Example.com/some/path  "
        XCTAssertEqual(model.domainToWatch(), "app.example.com")

        model.watchDomain = "   "
        XCTAssertNil(model.domainToWatch(), "leaving it empty is allowed")
    }

    /// A tenant that blocks API tokens must not be a dead end.
    func testManualSetupKeepsTheSiteAndSwitchesMode() {
        let model = model()
        model.submitLink()
        let board = model.partialBoardForManualSetup()

        XCTAssertEqual(board.site, "acme")
        XCTAssertEqual(board.mode, .prefilledURL)
    }

    func testGoingBackClearsTheErrorFromTheStepBeingLeft() async {
        StubURLProtocol.enqueue(.json("{}", status: 401))
        let model = model()
        model.submitLink()
        await model.connect()
        XCTAssertNotNil(model.errorMessage)

        model.back()
        XCTAssertEqual(model.step, .link)
        XCTAssertNil(model.errorMessage, "a stale error on an earlier step is just confusing")
    }

    func testBackStopsAtTheFirstStep() {
        let model = model()
        model.back()
        XCTAssertEqual(model.step, .link)
    }
}
