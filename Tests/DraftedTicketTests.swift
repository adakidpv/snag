import XCTest

final class DraftedTicketTests: XCTestCase {
    private func ticket(title: String) -> DraftedTicket {
        var t = DraftedTicket.empty
        t.title = title
        return t
    }

    func testTitleWithinLimitIsUntouched() {
        let title = "Chat confirms section added but canvas doesn't update"
        XCTAssertEqual(ticket(title: title).clampingTitle().title, title)
        XCTAssertLessThanOrEqual(title.count, DraftedTicket.titleLimit)
    }

    func testOverlongTitleIsClampedToLimit() {
        let title = String(repeating: "a", count: 200)
        let clamped = ticket(title: title).clampingTitle().title
        XCTAssertEqual(clamped.count, DraftedTicket.titleLimit)
    }

    func testClampPrefersAWordBoundaryNearTheLimit() {
        // 78 characters, then a space, then a word that pushes it over the ceiling.
        let title = String(repeating: "b", count: 78) + " overflowing"
        let clamped = ticket(title: title).clampingTitle().title
        XCTAssertEqual(clamped, String(repeating: "b", count: 78))
        XCTAssertFalse(clamped.hasSuffix(" "))
    }

    func testClampFallsBackToAHardCutWhenTheBoundaryIsTooFarBack() {
        // The only space is at the very start, far outside the 16-character window, so
        // cutting there would throw away almost the whole title.
        let title = "x " + String(repeating: "c", count: 200)
        let clamped = ticket(title: title).clampingTitle().title
        XCTAssertEqual(clamped.count, DraftedTicket.titleLimit)
        XCTAssertTrue(clamped.hasPrefix("x "))
    }

    func testAreaAndSeverityRoundTripThroughJSON() throws {
        var original = DraftedTicket.empty
        original.area = "publish"
        original.severity = .blocker
        original.stepsToReproduce = ["Open the editor", "Click Publish (assumed)"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DraftedTicket.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    /// `area` used to be an enum, and `snags.json` on an existing install is full of
    /// drafts written that way. The enum was string-backed, so those records have to go
    /// on decoding -- losing them would empty someone's Inbox on upgrade.
    func testDraftStoredWhenAreaWasAnEnumStillDecodes() throws {
        let json = #"""
        {"title":"Chat confirms section added but canvas doesn't update",
         "summary":"The assistant reports success; the canvas is unchanged.",
         "stepsToReproduce":["Open the editor","Ask chat for a pricing section"],
         "expected":"The new section appears.","actual":"The canvas is unchanged.",
         "area":"editor","severity":"major","labels":["canvas"]}
        """#
        let decoded = try JSONDecoder().decode(DraftedTicket.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.area, "editor")
        XCTAssertEqual(decoded.severity, .major)
        XCTAssertEqual(decoded.title, "Chat confirms section added but canvas doesn't update")
        XCTAssertEqual(decoded.labels, ["canvas"])
    }

    /// A whole record, as the store would have written it before the area became free
    /// text: the draft is nested inside it, so a decode failure would cost the record.
    func testStoredRecordWithAnEnumShapedAreaStillDecodes() throws {
        let json = #"""
        {"id":"3E2C1A90-5B4D-4F7E-8A21-9C0D6B3F1E54",
         "createdAt":792185475,"captureFilename":"snag-1.png","mediaType":"image",
         "context":{"capturedAt":792185475,"osVersion":"macOS 15.0"},
         "note":"canvas didn't update",
         "draft":{"title":"Canvas doesn't update","summary":"s","stepsToReproduce":[],
                  "expected":"e","actual":"a","area":"publish","severity":"blocker","labels":[]},
         "status":"filed","jiraKey":"ABC-412"}
        """#
        let record = try JSONDecoder().decode(SnagRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.draft?.area, "publish")
        XCTAssertEqual(record.draft?.severity, .blocker)
        XCTAssertEqual(record.jiraKey, "ABC-412")
    }
}
