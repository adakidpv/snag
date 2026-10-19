import AppKit
import SwiftUI

/// The Inbox: every reported snag, newest first, with a status filter and free-text
/// search over title, note, URL and Jira key.
struct InboxView: View {
    let store: SnagStore
    var onReopen: (SnagRecord) -> Void = { _ in }
    /// Captures changed hands, so the app can re-point the recents list and any report
    /// session that still refers to a record the merge removed.
    var onMerged: (SnagStore.MergeResult) -> Void = { _ in }
    /// A snag and its capture files are gone, so the app can let go of anything still
    /// holding them -- a Report panel open on that snag above all.
    var onDeleted: (UUID) -> Void = { _ in }

    @State private var statusFilter: SnagRecord.Status?
    @State private var query = ""
    /// A set rather than one id so rows can be ⌘- or shift-clicked into a group and
    /// reported as one ticket. One selected row behaves exactly as it always did.
    @State private var selection: Set<UUID> = []

    private var visible: [SnagRecord] {
        store.filtered(status: statusFilter, query: query)
    }

    private var selected: SnagRecord? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.record(id: id)
    }

    /// Oldest first, which is the order they'd be merged in.
    private var selectedRecords: [SnagRecord] {
        selection
            .compactMap { store.record(id: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Group {
            // With nothing reported at all, a split view is just a bare divider beside
            // half a window of nothing -- it reads as broken rather than empty. One
            // centred empty state says the same thing honestly.
            if store.records.isEmpty {
                emptyInbox
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

                    // The resolvable records, not the selected ids: a row whose record
                    // has gone shouldn't put a pane up with nothing behind it.
                    if selectedRecords.count > 1 {
                        InboxMergeView(
                            records: selectedRecords,
                            store: store,
                            onMerged: { result in
                                // Land on the ticket that survived, rather than on a
                                // selection half of which no longer exists.
                                selection = [result.record.id]
                                onMerged(result)
                            }
                        )
                        .frame(minWidth: 340)
                    } else if let selected {
                        InboxDetailView(
                            record: selected,
                            captureURL: store.captureURL(for: selected),
                            captureURLs: store.captureURLs(for: selected),
                            store: store,
                            onReopen: { onReopen(selected) },
                            onDeleted: { id in
                                // Land on the empty state rather than on a row that
                                // isn't there any more.
                                selection.remove(id)
                                onDeleted(id)
                            }
                        )
                        .frame(minWidth: 340)
                    } else {
                        emptyDetail.frame(minWidth: 340)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private var emptyInbox: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing reported yet")
                .font(.title3)
            Text("Take a screenshot on a watched page, then click Report.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search title, note, URL or key", text: $query)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $statusFilter) {
                    Text("All (\(store.records.count))").tag(SnagRecord.Status?.none)
                    ForEach(SnagRecord.Status.allCases) { status in
                        Text("\(status.label) (\(store.count(of: status)))")
                            .tag(SnagRecord.Status?.some(status))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)

            Divider()

            if visible.isEmpty {
                // Only reachable with records present but filtered out -- the
                // nothing-at-all case is handled before the split view.
                VStack(spacing: 4) {
                    Spacer()
                    Text("No matches").foregroundStyle(.secondary)
                    Text("Try a different search or filter.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(visible, selection: $selection) { record in
                    InboxRow(record: record, captureURL: store.captureURL(for: record))
                        .tag(record.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 4) {
            Spacer()
            Text("Select a snag")
                .foregroundStyle(.tertiary)
            Text("⌘-click a second one to report them as one ticket.")
                .font(.caption)
                .foregroundStyle(.quaternary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct InboxRow: View {
    let record: SnagRecord
    let captureURL: URL

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 9) {
            CaptureThumbnail(url: captureURL, mediaType: record.mediaType, width: 46, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    if record.hasMultipleCaptures {
                        Text("\(record.captureFilenames.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.black.opacity(0.6)))
                            .padding(2)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.draft?.title.nilIfEmpty ?? record.note.nilIfEmpty ?? "Untitled snag")
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    StatusBadge(status: record.status)
                    if let key = record.jiraKey {
                        Text(key).font(.caption2.weight(.medium))
                    }
                    Text(Self.dateFormatter.string(from: record.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: SnagRecord.Status

    private var color: Color {
        switch status {
        case .draft: return .orange
        case .filed: return .green
        case .dismissed: return .secondary
        }
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

/// What the detail pane shows while more than one row is selected: the captures those
/// snags would bring to one ticket, which snag survives, and the action.
///
/// This is the Inbox's answer to four shots taken ten minutes apart. The toast's **Add**
/// and the Report panel's **+ Add** both need the earlier capture to still be sitting
/// unreported under Recent captures; ten minutes and a report later it is a record of
/// its own, and only the Inbox can reach it.
private struct InboxMergeView: View {
    /// Oldest first.
    let records: [SnagRecord]
    let store: SnagStore
    let onMerged: (SnagStore.MergeResult) -> Void

    @State private var chosenPrimaryID: UUID?
    @State private var showConfirmation = false

    /// The snag that survives, keeping its id, note, Jira key, status and date. The
    /// oldest unless the user picks another -- usually it's the one they started
    /// writing on, and always the one whose date puts the ticket where they expect it.
    private var primary: SnagRecord {
        records.first { $0.id == chosenPrimaryID } ?? records[0]
    }

    private var mergedAway: [SnagRecord] { records.filter { $0.id != primary.id } }

    /// Merging away a snag that's already in Jira leaves that issue behind, untouched:
    /// nothing here updates Jira. Named rather than silently folded in.
    private var filedAway: [SnagRecord] {
        mergedAway.filter { $0.status == .filed || $0.jiraKey != nil }
    }

    private var refusal: SnagStore.MergeRefusal? {
        store.mergeRefusal(for: records.map(\.id))
    }

    /// Every capture the merged ticket would carry, in the order it would carry them:
    /// the surviving snag's first, then the rest oldest record first.
    private var captures: [Preview] {
        ([primary] + mergedAway)
            .flatMap { record in
                store.captureURLs(for: record).map { Preview(url: $0, mediaType: record.mediaType) }
            }
    }

    private struct Preview: Identifiable {
        let url: URL
        let mediaType: SnagRecord.MediaType
        var id: URL { url }
    }

    /// Where this capture sits on the merged ticket, 1-based — the same numbering the
    /// Report panel and the draft use.
    private func position(of capture: Preview) -> Int {
        (captures.firstIndex(where: { $0.url == capture.url }) ?? 0) + 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(records.count) snags selected")
                        .font(.headline)
                    Text("Report them as one ticket carrying \(captures.count) captures.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(captures) { capture in
                            CaptureThumbnail(
                                url: capture.url,
                                mediaType: capture.mediaType,
                                width: 94,
                                height: 59
                            )
                            .overlay(alignment: .topLeading) {
                                Text("\(position(of: capture))")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.55)))
                                    .padding(3)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                Divider()

                keepSection

                if !filedAway.isEmpty { filedWarning }
                if primary.status == .filed || primary.jiraKey != nil { keptIsFiledNote }

                if let refusal {
                    Label(refusal.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Button("Report together") { showConfirmation = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(refusal != nil)
                    Spacer()
                }

                Text("The others leave the Inbox; their captures move to the ticket you keep. Nothing is deleted.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        // A changed selection makes a chosen primary meaningless -- and would silently
        // fall back to the oldest anyway, so clear it rather than let it look chosen.
        .onChange(of: records.map(\.id)) { _, _ in chosenPrimaryID = nil }
        .confirmationDialog(
            "Report \(records.count) snags as one ticket?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Report together") { merge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var keepSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Keep").font(.caption.weight(.semibold))
            Menu(Self.label(for: primary)) {
                ForEach(records) { record in
                    Button(Self.label(for: record)) { chosenPrimaryID = record.id }
                }
            }
            .fixedSize()
            Text("Its note, date, status and Jira key are the ticket's.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var filedWarning: some View {
        let keys = filedAway.compactMap { $0.jiraKey }
        let named = keys.isEmpty ? "One of them" : keys.joined(separator: ", ")
        return Label(
            "\(named) \(keys.count > 1 ? "are" : "is") already filed in Jira. "
                + "Merging won't change \(keys.count > 1 ? "those issues" : "that issue") — "
                + "keep it instead if its ticket is the one you want.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
    }

    /// Keeping a filed snag is allowed -- it's the way to merge without abandoning an
    /// issue -- but the captures arriving on it don't reach Jira either, so say so
    /// rather than let the ticket look complete.
    private var keptIsFiledNote: some View {
        Label(
            "\(primary.jiraKey ?? "The snag you're keeping") is already filed. The captures "
                + "moving onto it aren't sent to Jira — attach them there yourself.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var confirmationMessage: String {
        let base = "\(mergedAway.count) snag\(mergedAway.count > 1 ? "s" : "") "
            + "leave\(mergedAway.count > 1 ? "" : "s") the Inbox and their captures move to "
            + "\(Self.label(for: primary)). No capture file is deleted."
        guard !filedAway.isEmpty else { return base }
        let keys = filedAway.compactMap { $0.jiraKey }
        let named = keys.isEmpty ? "A filed snag" : keys.joined(separator: ", ")
        return base + "\n\n\(named) stays in Jira exactly as it is — this doesn't update it."
    }

    private func merge() {
        guard let result = store.merge(
            into: primary.id,
            from: mergedAway.map(\.id)
        ) else { return }
        onMerged(result)
    }

    private static func label(for record: SnagRecord) -> String {
        let title = record.draft?.title.nilIfEmpty
            ?? record.note.nilIfEmpty
            ?? record.jiraKey
            ?? "Untitled snag"
        return title.count > 42 ? String(title.prefix(42)) + "…" : title
    }
}

/// Detail pane: the capture, the drafted ticket if there is one, and the three things
/// the brief asks for here -- re-open the Report panel, paste a Jira key, change status
/// or delete.
private struct InboxDetailView: View {
    let record: SnagRecord
    let captureURL: URL
    /// Primary first; the primary is shown large and the rest as a strip beneath it.
    var captureURLs: [URL] = []
    let store: SnagStore
    let onReopen: () -> Void
    /// Raised after the delete, so the app can close a Report panel that was open on
    /// this snag -- its capture files are gone and its record with them.
    var onDeleted: (UUID) -> Void = { _ in }

    @State private var keyField = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CaptureThumbnail(url: captureURL, mediaType: record.mediaType, width: 300, height: 190)
                    .onTapGesture { NSWorkspace.shared.open(captureURL) }
                    .help("Click to open the capture")

                if captureURLs.count > 1 {
                    HStack(spacing: 7) {
                        ForEach(Array(captureURLs.dropFirst().enumerated()), id: \.element) { index, url in
                            CaptureThumbnail(
                                url: url,
                                mediaType: record.mediaType,
                                width: 94,
                                height: 59
                            )
                            .overlay(alignment: .topLeading) {
                                Text("\(index + 2)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.55)))
                                    .padding(3)
                            }
                            .onTapGesture { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                if let draft = record.draft {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(draft.title).font(.headline)
                        Text(draft.summary).font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if let area = draft.area.nilIfEmpty {
                                Label(area.capitalized, systemImage: "square.grid.2x2")
                            }
                            Label(draft.severity.label, systemImage: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(record.note.nilIfEmpty ?? "No note")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                contextSection

                Divider()

                jiraSection

                Divider()

                HStack {
                    Button("Open in Report panel", action: onReopen)
                    Spacer()
                    Menu("Status: \(record.status.label)") {
                        ForEach(SnagRecord.Status.allCases) { status in
                            Button(status.label) { store.setStatus(status, for: record.id) }
                        }
                    }
                    .fixedSize()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this snag and its capture")
                }
            }
            .padding(16)
        }
        // Reset the field when switching records, or a key typed for one snag would
        // appear to belong to the next.
        .onChange(of: record.id) { _, _ in keyField = record.jiraKey ?? "" }
        .onAppear { keyField = record.jiraKey ?? "" }
        .confirmationDialog(
            "Delete this snag?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(id: record.id)
                onDeleted(record.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The capture file is deleted too. This can't be undone.")
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = record.context.url {
                Link(url, destination: URL(string: url) ?? URL(fileURLWithPath: "/"))
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if let env = record.context.env { Text("env: \(env)") }
                if let browser = record.context.browserName { Text(browser) }
                Text(record.context.osVersion)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var jiraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Jira key").font(.caption.weight(.semibold))

            if let key = record.jiraKey, let board = board(for: record),
               let url = JiraKey.browseURL(site: board.site, key: key) {
                HStack {
                    Link(key, destination: url).font(.callout.weight(.medium))
                    Button("Clear") { store.setJiraKey(nil, for: record.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                HStack {
                    TextField("ABC-412", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onSubmit { store.setJiraKey(keyField, for: record.id) }
                    Button("Save") { store.setJiraKey(keyField, for: record.id) }
                        .disabled(JiraKey.normalize(keyField) == nil)
                }
                if let key = record.jiraKey {
                    // Saved, but no board to build a link from.
                    Text("\(key) — set this snag's board to get a link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Resolved through the store's settings owner in the app; nil until a board is set.
    private func board(for record: SnagRecord) -> Board? {
        record.boardID.flatMap { id in BoardRegistry.shared.board(id: id) }
    }
}

/// Lets views resolve a board by id without threading `AppSettings` through every
/// initialiser. Set once at launch.
@MainActor
final class BoardRegistry {
    static let shared = BoardRegistry()
    private var lookup: () -> [Board] = { [] }

    func configure(_ lookup: @escaping () -> [Board]) {
        self.lookup = lookup
    }

    func board(id: UUID) -> Board? {
        lookup().first { $0.id == id }
    }
}
