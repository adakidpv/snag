import XCTest

/// The brief requires the API key to live in the Keychain and nowhere else, so this
/// exercises the real `SecItem` calls rather than trusting the code by inspection.
///
/// Uses a throwaway account name under the app's service and removes it afterwards, so
/// it never touches a real stored key.
final class KeychainTests: XCTestCase {
    private var account: String!

    override func setUp() {
        super.setUp()
        account = "unit-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? Keychain.delete(account: account)
        super.tearDown()
    }

    func testWriteThenReadRoundTrips() throws {
        try Keychain.write("sk-ant-secret-value", account: account)
        XCTAssertEqual(Keychain.read(account: account), "sk-ant-secret-value")
        XCTAssertTrue(Keychain.has(account: account))
    }

    func testMissingAccountReadsAsNil() {
        XCTAssertNil(Keychain.read(account: account))
        XCTAssertFalse(Keychain.has(account: account))
    }

    /// Writing twice must update in place, not create a second item that then makes
    /// reads ambiguous.
    func testSecondWriteUpdatesInPlace() throws {
        try Keychain.write("first", account: account)
        try Keychain.write("second", account: account)
        XCTAssertEqual(Keychain.read(account: account), "second")
    }

    func testWritingNilRemovesTheItem() throws {
        try Keychain.write("value", account: account)
        try Keychain.write(nil, account: account)
        XCTAssertNil(Keychain.read(account: account))
    }

    /// A blank field in Settings should clear the key rather than store "".
    func testWritingBlankRemovesTheItem() throws {
        try Keychain.write("value", account: account)
        try Keychain.write("   ", account: account)
        XCTAssertNil(Keychain.read(account: account))
    }

    func testDeletingSomethingAbsentIsNotAnError() {
        XCTAssertNoThrow(try Keychain.delete(account: account))
    }

    func testAccountsAreIndependent() throws {
        let other = "unit-test-other-\(UUID().uuidString)"
        defer { try? Keychain.delete(account: other) }

        try Keychain.write("anthropic", account: account)
        try Keychain.write("jira", account: other)

        XCTAssertEqual(Keychain.read(account: account), "anthropic")
        XCTAssertEqual(Keychain.read(account: other), "jira")
    }

    /// Per-board token accounts must not collide.
    func testJiraTokenAccountsAreScopedPerBoard() {
        let a = Keychain.Account.jiraToken(boardID: UUID())
        let b = Keychain.Account.jiraToken(boardID: UUID())
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("jira-token:"))
    }

    func testKeysWithAwkwardCharactersSurvive() throws {
        let value = "sk-ant-ÅÄÖ-\u{1F600}-/+=:;\"'"
        try Keychain.write(value, account: account)
        XCTAssertEqual(Keychain.read(account: account), value)
    }
}
