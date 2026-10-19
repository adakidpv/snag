import XCTest

/// Covers the lookups onboarding depends on, offline. The point of these is that a user
/// never types a numeric id, so the id-resolving paths and every failure the setup flow
/// has to explain are both worth proving without a tenant.
final class JiraDiscoveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func discovery(token: String = "token123") -> JiraDiscovery {
        JiraDiscovery(
            site: "example",
            accountEmail: "qa@example.com",
            apiToken: token,
            session: StubURLProtocol.session()
        )
    }

    private func failureOf(_ operation: () async throws -> Void) async -> JiraDiscovery.Failure? {
        do {
            try await operation()
            return nil
        } catch let failure as JiraDiscovery.Failure {
            return failure
        } catch {
            return nil
        }
    }

    // MARK: - Request shape

    func testRequestsAreAuthenticatedGETsThatAskForJSON() async throws {
        StubURLProtocol.enqueue(.json(#"{"accountId":"5b10a2","displayName":"Akhil"}"#))
        _ = try await discovery().me()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "example.atlassian.net")
        XCTAssertEqual(request.url?.path, "/rest/api/3/myself")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        let encoded = try XCTUnwrap(header.split(separator: " ").last).description
        let decoded = String(data: try XCTUnwrap(Data(base64Encoded: encoded)), encoding: .utf8)
        XCTAssertEqual(decoded, "qa@example.com:token123", "Basic auth is email plus API token")
    }

    /// Credentials are checked before anything is sent, so a half-filled form doesn't
    /// produce a confusing 401 from Jira.
    func testMissingTokenFailsBeforeAnyRequestIsMade() async {
        let result = await failureOf { _ = try await self.discovery(token: "").me() }
        guard case .invalidConfiguration = result else {
            return XCTFail("expected an invalidConfiguration failure, got \(String(describing: result))")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "nothing should reach the network")
    }

    // MARK: - Who am I

    func testMyselfPrefillsTheEmailWhenTheProfileExposesIt() async throws {
        StubURLProtocol.enqueue(.json(#"""
        {"accountId":"5b10a2","displayName":"Akhil Anil","emailAddress":"qa@example.com"}
        """#))
        let account = try await discovery().me()

        XCTAssertEqual(account.accountID, "5b10a2")
        XCTAssertEqual(account.displayName, "Akhil Anil")
        XCTAssertEqual(account.email, "qa@example.com")
    }

    /// Atlassian lets a profile hide its email, and many tenants do. Onboarding has to
    /// keep asking for it rather than inventing one.
    func testMyselfLeavesTheEmailNilWhenTheProfileHidesIt() async throws {
        StubURLProtocol.enqueue(.json(#"{"accountId":"5b10a2","displayName":"Akhil Anil"}"#))
        let account = try await discovery().me()
        XCTAssertNil(account.email)
    }

    // MARK: - Resolving a project

    private static let projectJSON = #"""
    {"id":"10001","key":"ABC","name":"Acme Web","issueTypes":[
      {"id":"10004","name":"Bug","subtask":false},
      {"id":"10001","name":"Task","subtask":false},
      {"id":"10005","name":"Bug sub-task","subtask":true}
    ]}
    """#

    func testProjectResolvesBothIdsInASingleRequest() async throws {
        StubURLProtocol.enqueue(.json(Self.projectJSON))
        let project = try await discovery().project(key: "ABC")

        XCTAssertEqual(project.id, "10001", "the numeric project id the create needs")
        XCTAssertEqual(project.key, "ABC")
        XCTAssertEqual(project.name, "Acme Web")
        XCTAssertEqual(project.likelyBugType?.id, "10004", "and the issue type id, from the same call")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "one request, not a second lookup for types")
    }

    func testProjectRequestAsksForIssueTypesAndUppercasesTheKey() async throws {
        StubURLProtocol.enqueue(.json(Self.projectJSON))
        _ = try await discovery().project(key: " abc ")

        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/rest/api/3/project/ABC")
        XCTAssertEqual(url.query, "expand=issueTypes")
    }

    /// A subtask type can't be created on its own, so it's never the default.
    func testFallsBackToTheFirstNonSubtaskTypeWhenThereIsNoBug() async throws {
        StubURLProtocol.enqueue(.json(#"""
        {"id":"1","key":"X","name":"X","issueTypes":[
          {"id":"9","name":"Bug sub-task","subtask":true},
          {"id":"7","name":"Defect","subtask":false}
        ]}
        """#))
        let project = try await discovery().project(key: "X")
        XCTAssertEqual(project.likelyBugType?.id, "7")
    }

    /// Jira is inconsistent about quoting numeric ids between endpoints.
    func testAcceptsIdsWhetherQuotedOrNot() async throws {
        StubURLProtocol.enqueue(.json(#"""
        {"id":10001,"key":"ABC","name":"N","issueTypes":[{"id":10004,"name":"Bug","subtask":false}]}
        """#))
        let project = try await discovery().project(key: "ABC")
        XCTAssertEqual(project.id, "10001")
        XCTAssertEqual(project.likelyBugType?.id, "10004")
    }

    // MARK: - Listing projects

    func testProjectSearchReadsTheValuesArrayAndPassesTheQuery() async throws {
        StubURLProtocol.enqueue(.json(#"""
        {"values":[
          {"id":"1","key":"AAA","name":"Alpha","issueTypes":[]},
          {"id":"2","key":"BBB","name":"Beta","issueTypes":[]}
        ]}
        """#))
        let projects = try await discovery().projects(matching: "al")

        XCTAssertEqual(projects.map(\.key), ["AAA", "BBB"])
        let query = try XCTUnwrap(StubURLProtocol.requests.first?.url?.query)
        XCTAssertTrue(query.contains("query=al"), "got \(query)")
    }

    func testProjectSearchOmitsABlankQuery() async throws {
        StubURLProtocol.enqueue(.json(#"{"values":[]}"#))
        _ = try await discovery().projects(matching: "   ")

        let query = try XCTUnwrap(StubURLProtocol.requests.first?.url?.query)
        XCTAssertFalse(query.contains("query="), "an empty query would filter everything out")
    }

    // MARK: - Failures onboarding has to explain

    func testUnknownProjectKeyIsReportedAsNotFound() async {
        StubURLProtocol.enqueue(.json(#"{"errorMessages":["No project could be found"]}"#, status: 404))
        let result = await failureOf { _ = try await self.discovery().project(key: "NOPE") }
        XCTAssertEqual(result, .projectNotFound(key: "NOPE"))
    }

    func testRejectedCredentialsAreReportedAsUnauthorized() async {
        StubURLProtocol.enqueue(.json("{}", status: 401))
        let result = await failureOf { _ = try await self.discovery().me() }
        XCTAssertEqual(result, .unauthorized)
        XCTAssertTrue(
            result?.errorDescription?.contains("isn't your") == true,
            "the message must say the token is not the account password"
        )
    }

    /// Signed in but not permitted is a different fix from a bad token, so it must be a
    /// different message.
    func testForbiddenIsDistinctFromUnauthorized() async {
        StubURLProtocol.enqueue(.json("{}", status: 403))
        let result = await failureOf { _ = try await self.discovery().project(key: "ABC") }
        XCTAssertEqual(result, .forbidden)
    }

    func testUnexpectedStatusCarriesJirasOwnDetail() async {
        StubURLProtocol.enqueue(.json(#"{"errorMessages":["Something broke"]}"#, status: 500))
        let result = await failureOf { _ = try await self.discovery().me() }
        XCTAssertEqual(result, .unexpected(status: 500, detail: "Something broke"))
    }

    func testOfflineIsReportedAsOffline() async {
        StubURLProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
        let result = await failureOf { _ = try await self.discovery().me() }
        guard case .offline = result else {
            return XCTFail("expected an offline failure, got \(String(describing: result))")
        }
    }

    // MARK: - Required fields Snag can't fill

    private func unfillable(_ json: String) -> [JiraDiscovery.RequiredField] {
        JiraDiscovery.unfillableRequiredFields(in: Data(json.utf8))
    }

    func testReportsARequiredCustomFieldWithNoDefault() {
        let fields = unfillable(#"""
        {"values":[
          {"fieldId":"summary","name":"Summary","required":true,"hasDefaultValue":false},
          {"fieldId":"customfield_10050","name":"Severity","required":true,"hasDefaultValue":false},
          {"fieldId":"customfield_10051","name":"Team","required":true,"hasDefaultValue":true},
          {"fieldId":"customfield_10052","name":"Notes","required":false,"hasDefaultValue":false}
        ]}
        """#)

        XCTAssertEqual(fields, [.init(id: "customfield_10050", name: "Severity")],
                       "only the one that blocks a create: required, no default, not ours to send")
    }

    func testEveryFieldSnagSendsIsExcluded() {
        let json = "{\"values\":[" + JiraDiscovery.fieldsSnagFills.map {
            "{\"fieldId\":\"\($0)\",\"name\":\"\($0)\",\"required\":true,\"hasDefaultValue\":false}"
        }.joined(separator: ",") + "]}"
        XCTAssertTrue(unfillable(json).isEmpty)
    }

    /// The docs have carried this list under three different keys across revisions.
    func testFieldListIsFoundUnderValuesFieldsOrResults() {
        let field = #"{"fieldId":"customfield_1","name":"Severity","required":true,"hasDefaultValue":false}"#
        for key in ["values", "fields", "results"] {
            XCTAssertEqual(
                unfillable("{\"\(key)\":[\(field)]}").map(\.name), ["Severity"],
                "field list under \(key) was not read"
            )
        }
    }

    /// The older endpoint returned a map keyed by field id instead of an array.
    func testLegacyFieldMapShapeIsRead() {
        let fields = unfillable(#"""
        {"fields":{
          "summary":{"name":"Summary","required":true,"hasDefaultValue":false},
          "customfield_10050":{"name":"Severity","required":true,"hasDefaultValue":false}
        }}
        """#)
        XCTAssertEqual(fields, [.init(id: "customfield_10050", name: "Severity")])
    }

    /// A shape nobody anticipated must not take setup down -- the check is a warning,
    /// not a gate.
    func testAnUnreadableResponseReportsNothingRatherThanFailing() {
        XCTAssertTrue(unfillable("not json at all").isEmpty)
        XCTAssertTrue(unfillable("{}").isEmpty)
        XCTAssertTrue(unfillable(#"{"values":"surprise"}"#).isEmpty)
    }

    func testRequiredFieldsAreOrderedStably() {
        let fields = unfillable(#"""
        {"values":[
          {"fieldId":"customfield_2","name":"Zebra","required":true,"hasDefaultValue":false},
          {"fieldId":"customfield_1","name":"Apple","required":true,"hasDefaultValue":false}
        ]}
        """#)
        XCTAssertEqual(fields.map(\.name), ["Apple", "Zebra"])
    }
}
