import SwiftUI
import UIKit

/// Local Verlauf — chronological list of recorded sessions (walkthrough
/// + note) grouped by day. Tapping a row opens the detail view.
/// Swiping a row from the right reveals the iOS-typical destructive
/// delete action (asks for confirmation via the .destructive role).
@MainActor
public struct VerlaufView: View {
    @State private var items: [SessionHistoryStore.Item] = []
    @State private var deleteError: String?

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "History")

                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(groupedByDay(), id: \.dayKey) { section in
                            Section {
                                ForEach(section.items) { item in
                                    row(for: item)
                                }
                            } header: {
                                Text(section.label)
                                    .font(Theme.font.caption)
                                    .foregroundStyle(Theme.color.text.subdued)
                                    .tracking(0.6)
                                    .textCase(.uppercase)
                                    .padding(.leading, Theme.spacing.xxs)
                                    .padding(.top, Theme.spacing.sm)
                            }
                        }
                    }
                    // Plain list — no rounded card border surrounding
                    // each day group. The day header itself separates
                    // the groups; row dividers handle inter-row spacing.
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                if let deleteError {
                    Text(deleteError)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.status.destructive)
                        .padding(Theme.spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationBarHidden(true)
        // `.onAppear` (not `.task`) so the list re-scans when the user
        // pops back from a detail page after deleting that entry there.
        .onAppear { reload() }
        .refreshable { reload() }
    }

    @ViewBuilder
    private func row(for item: SessionHistoryStore.Item) -> some View {
        NavigationLink {
            VerlaufDetailView(item: item)
        } label: {
            VerlaufRow(item: item)
        }
        .listRowBackground(Theme.color.bg.surface)
        .listRowSeparator(.visible)
        .listRowInsets(EdgeInsets(top: 10, leading: Theme.spacing.md,
                                  bottom: 10, trailing: Theme.spacing.md))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Icon-only delete button. `.iconOnly` label style strips
            // the "Löschen" text so the swipe action is just a tall
            // trash glyph that fills the row height (the iOS default
            // for swipe-action vertical sizing).
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacing.sm) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Theme.color.text.subdued)
            Text("No sessions yet")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text("Walkthrough and note recordings show up here.")
                .font(Theme.font.callout)
                .foregroundStyle(Theme.color.text.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        items = SessionHistoryStore.load()
    }

    private func delete(_ item: SessionHistoryStore.Item) {
        do {
            try SessionHistoryStore.delete(item)
            items.removeAll { $0.id == item.id }
            deleteError = nil
            // Belt-and-braces: drop any matching upload-queue entry so
            // we don't keep retrying an upload whose source is gone.
            Task { _ = await SessionUploader.shared.purgeOrphans() }
        } catch {
            deleteError = String(localized:
                "Delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Day grouping

    private struct DaySection {
        let dayKey: Date          // start-of-day used as Identifiable key
        let label: String
        let items: [SessionHistoryStore.Item]
    }

    private func groupedByDay() -> [DaySection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.sortDate)
        }
        return groups.keys.sorted(by: >).map { day in
            DaySection(
                dayKey: day,
                label: Self.dayLabel(day),
                items: groups[day] ?? []
            )
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "Today") }
        if cal.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return Self.dayFormatter().string(from: day)
    }

    // DateFormatter is sensitive to AppLanguage at call time. The pattern
    // works for both German ("Montag, 12. Mai") and English ("Monday,
    // May 12") because DateFormatter localises `EEEE / MMMM` per locale
    // and reorders the components according to the locale's own
    // dateFormat template logic. We rebuild on each call rather than
    // mutating a cached instance so toggle is single-render-tick visible.
    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        let template = AppLanguage.shared.isGerman ? "EEEE, d. MMMM" : "EEEE, MMMM d"
        f.dateFormat = template
        return f
    }
}

// MARK: - Row

private struct VerlaufRow: View {
    let item: SessionHistoryStore.Item

    var body: some View {
        HStack(spacing: Theme.spacing.sm) {
            // Tinted icon disc — distinguishes walkthrough vs note
            // at a glance without leaning on a glyph alone.
            ZStack {
                Circle()
                    .fill(iconBg)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconFg)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font.body.weight(.medium))
                    .foregroundStyle(Theme.color.text.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var icon: String {
        switch item {
        case .walkthrough: return "book.closed.fill"
        case .voiceNote:     return "mic.fill"
        }
    }

    private var iconBg: Color {
        switch item {
        case .walkthrough: return Theme.color.tint.link10
        case .voiceNote:     return Theme.color.tint.warning10
        }
    }

    private var iconFg: Color {
        switch item {
        case .walkthrough: return Theme.color.text.link
        case .voiceNote:     return Theme.color.status.warning
        }
    }

    private var title: String {
        switch item {
        case .walkthrough(let w):
            switch w.eventCount {
            case 0: return String(localized: "Evening session")
            case 1: return String(localized: "Evening session · 1 event")
            default: return String(localized: "Evening session · \(w.eventCount) events")
            }
        case .voiceNote(let d):
            let preview = d.note.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? String(localized: "Note") : preview
        }
    }

    /// Subtitle is the **date the recording is for**. The list above is
    /// already grouped by capture day, so the row no longer restates
    /// when it was recorded — the second line is the *subject* day
    /// (manifest.date for walkthrough, captured_at for note) so a
    /// session captured today *for* last Tuesday reads correctly.
    private var subtitle: String {
        switch item {
        case .walkthrough(let w):
            // manifest.date is "yyyy-MM-dd"; if missing, fall back to
            // the capture day so we still show something useful.
            let base: Date = {
                if let str = w.manifest?.date,
                   let parsed = Self.isoDay.date(from: str) {
                    return parsed
                }
                return w.capturedAt
            }()
            return String(localized: "For \(Self.relativeDay().string(from: base))")
        case .voiceNote(let d):
            return String(localized:
                "For \(Self.relativeDay().string(from: d.note.captured_at))")
        }
    }

    /// "yyyy-MM-dd" parser for manifest.date.
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Today" / "Yesterday" / "Wednesday, April 30" — or the German
    /// equivalents. Locale picked at call time from AppLanguage.
    static func relativeDay() -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }
}

// MARK: - Detail

@MainActor
struct VerlaufDetailView: View {
    let item: SessionHistoryStore.Item

    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var isPreparing: Bool = false
    @State private var prepareError: String?
    @State private var showShare: Bool = false
    @State private var serverStatus: ServerClient.SessionStatusResponse?
    @State private var serverStatusFetched: Bool = false
    @State private var player = SegmentPlayer()
    /// Segment ids swiped away in this view — filtered out of the list.
    /// (Walkthrough detail; the underlying audio file is removed too.)
    @State private var deletedSegmentIDs: Set<String> = []
    /// Surfaced-note ids swiped away in this view.
    @State private var deletedNoteIDs: Set<String> = []

    var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                // `title` is built from runtime data + `String(localized:)`,
                // so it's already in the user's language. Use the
                // verbatim init to avoid running it back through the
                // catalog as a key.
                FlowHeader(verbatim: title)

                // List (not ScrollView) so each segment / note row gets a
                // native swipe-to-delete — the same affordance as the
                // Verlauf list and the Gefahrenzone. The hero + stats +
                // footer ride along as chrome-free rows. Whole-entry
                // deletion lives in the Verlauf list, so there's no
                // destructive button here anymore.
                List {
                    clearRow { heroCard }
                    clearRow { statsGrid }

                    segmentsSection
                    notesSection

                    clearRow { identifierFooter }
                    if let prepareError {
                        clearRow {
                            Text(prepareError)
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.status.destructive)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Keep the last rows clear of the floating share button.
                .contentMargins(.bottom, 96, for: .scrollContent)
            }

            VStack {
                Spacer()
                BottomActionStack {
                    Button(action: prepareAndShare) {
                        if isPreparing {
                            HStack(spacing: Theme.spacing.xs) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(Theme.color.text.inverse)
                                Text("Preparing audio…")
                            }
                        } else {
                            Label("Share audio", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
                    .disabled(isPreparing)
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .task { await loadServerStatus() }
        .onDisappear { player.stop() }
    }

    // MARK: - List sections

    /// Chrome-free list row for the hero / stats / footer cards: the card
    /// keeps its own rounded background, the row itself stays transparent
    /// and separator-free so it reads as floating chrome, not a list item.
    @ViewBuilder
    private func clearRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.spacing.xs, leading: Theme.spacing.md,
                                      bottom: Theme.spacing.xs, trailing: Theme.spacing.md))
    }

    private func sectionHeaderLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.monoCaption)
            .foregroundStyle(Theme.color.text.subdued)
            .tracking(0.5)
            .textCase(nil)
    }

    @ViewBuilder
    private var segmentsSection: some View {
        let segs = visibleSegments
        if !segs.isEmpty {
            Section {
                ForEach(segs) { d in
                    SegmentRow(descriptor: d, player: player)
                        .listRowBackground(Theme.color.bg.surface)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.spacing.md,
                                                  bottom: 8, trailing: Theme.spacing.md))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deleteSegment(d) } label: {
                                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                            }
                        }
                }
            } header: { sectionHeaderLabel(String(localized: "SECTIONS")) }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        let notes = visibleNotes
        if !notes.isEmpty {
            Section {
                ForEach(notes, id: \.note.seed_id) { e in
                    NoteRow(entry: e, player: player)
                        .listRowBackground(Theme.color.bg.surface)
                        .listRowInsets(EdgeInsets(top: 8, leading: Theme.spacing.md,
                                                  bottom: 8, trailing: Theme.spacing.md))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deleteNote(e) } label: {
                                Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                            }
                        }
                }
            } header: { sectionHeaderLabel(String(localized: "NOTES")) }
        }
    }

    private var visibleSegments: [SegmentDescriptor] {
        sectionDescriptors().filter { !deletedSegmentIDs.contains($0.id) }
    }
    private var visibleNotes: [SurfacedNoteEntry] {
        surfacedNoteEntries().filter { !deletedNoteIDs.contains($0.note.seed_id) }
    }

    // MARK: - Per-row deletion

    /// Delete one segment. For a walkthrough that's the segment's audio
    /// file (the session and its other segments stay). For a note detail
    /// the single row *is* the whole note, so it deletes the note and
    /// pops back. A removed source also drops any pending upload.
    private func deleteSegment(_ d: SegmentDescriptor) {
        switch item {
        case .voiceNote:
            player.stop()
            try? SessionHistoryStore.delete(item)
            Task { _ = await SessionUploader.shared.purgeOrphans() }
            dismiss()
        case .walkthrough:
            if player.activeURL == d.audioURL { player.stop() }
            if let url = d.audioURL { try? FileManager.default.removeItem(at: url) }
            deletedSegmentIDs.insert(d.id)
            Task { _ = await SessionUploader.shared.purgeOrphans() }
        }
    }

    /// Delete one surfaced note. A surfaced note is a standalone drive-by
    /// recording living under `driveby_seeds/`, so this removes its whole
    /// directory — it disappears from the Verlauf list too.
    private func deleteNote(_ e: SurfacedNoteEntry) {
        if player.activeURL == e.audioURL { player.stop() }
        try? FileManager.default.removeItem(at: e.audioURL.deletingLastPathComponent())
        deletedNoteIDs.insert(e.note.seed_id)
        Task { _ = await SessionUploader.shared.purgeOrphans() }
    }

    private func loadServerStatus() async {
        guard !serverStatusFetched else { return }
        serverStatusFetched = true
        let sessionID: String
        switch item {
        case .walkthrough(let w): sessionID = w.sessionID
        case .voiceNote:            return  // notes upload as part of a session, no per-note status
        }
        do {
            serverStatus = try await ServerClient.shared.sessionStatus(sessionID: sessionID)
        } catch {
            // Network/auth errors are non-fatal — leave the pill as "unknown".
            serverStatus = nil
        }
    }

    private var title: String {
        switch item {
        case .walkthrough: return String(localized: "Evening")
        case .voiceNote:   return String(localized: "Note")
        }
    }

    // MARK: - Composition

    /// Hero header: tinted icon disc + "aufgenommen: <date>, <time>"
    /// beside it. Walkthroughs add a "Tagebucheintrag:" block below.
    /// The session type (Abend / Note) already lives in the page
    /// title, so no headline duplicates it here.
    private var heroCard: some View {
        let icon: String
        let iconBg: Color
        let iconFg: Color
        let captured: Date
        let diaryDate: Date?
        switch item {
        case .walkthrough(let w):
            icon = "book.closed.fill"
            iconBg = Theme.color.tint.link10
            iconFg = Theme.color.text.link
            captured = w.capturedAt
            diaryDate = w.diaryDate
        case .voiceNote(let d):
            icon = "mic.fill"
            iconBg = Theme.color.tint.warning10
            iconFg = Theme.color.status.warning
            captured = d.note.captured_at
            diaryDate = nil
        }
        let recordedLine = Self.heroDayShort().string(from: captured)
            + " · "
            + Self.heroTime.string(from: captured)

        return VStack(alignment: .leading, spacing: Theme.spacing.md) {
            HStack(alignment: .center, spacing: Theme.spacing.md) {
                ZStack {
                    Circle().fill(iconBg).frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(iconFg)
                }
                Text(recordedLine)
                    .font(Theme.font.subheadline.weight(.medium))
                    .foregroundStyle(Theme.color.text.primary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let diaryDate {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diary entry:")
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                    Text(Self.diaryDay().string(from: diaryDate))
                        .font(Theme.font.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.color.text.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    /// Three-tile stats grid — quick-glance facts about the session.
    /// Fewer numbers, bigger type, easier to scan than a label/value list.
    private var statsGrid: some View {
        let tiles: [StatTile.Model]
        switch item {
        case .walkthrough(let w):
            let totalMB = Double(w.totalBytes) / 1_000_000
            tiles = [
                .init(value: "\(w.eventCount)",
                      label: String(localized: "Events")),
                .init(value: "\(w.segmentURLs.count)",
                      label: String(localized: "Segments")),
                .init(value: String(format: "%.1f MB", totalMB),
                      label: String(localized: "Size")),
            ]
        case .voiceNote(let d):
            let bytes = (try? d.directory.appending(path: "audio.m4a")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let kb = Double(bytes) / 1_000
            tiles = [
                .init(value: String(format: "%.0f", d.note.duration_seconds.rounded()) + " s",
                      label: String(localized: "Duration")),
                .init(value: d.note.language.uppercased(),
                      label: String(localized: "Language")),
                .init(value: String(format: "%.0f KB", kb),
                      label: String(localized: "Size")),
            ]
        }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Theme.spacing.sm),
                           count: tiles.count),
            spacing: Theme.spacing.sm
        ) {
            ForEach(tiles) { StatTile(model: $0) }
        }
    }

    /// Footer with the technical identifier in a mono caption.
    /// Recessed visually so it doesn't compete with the content above.
    private var identifierFooter: some View {
        let label: String
        let value: String
        switch item {
        case .walkthrough(let w):
            label = "SESSION-ID"
            value = w.sessionID
        case .voiceNote(let d):
            label = "SEED-ID"
            value = d.note.id
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.subdued)
                .tracking(0.5)
            Text(value)
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.subdued)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.spacing.sm)
    }

    // All hero-related DateFormatters rebuild per call so AppLanguage
    // flips on the same screen. Using `setLocalizedDateFormatFromTemplate`
    // lets DateFormatter reorder fields per locale (German keeps
    // "Freitag, 1. Mai 2026"; English emits "Friday, May 1, 2026").

    static func heroDay() -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        f.setLocalizedDateFormatFromTemplate("EEEE, d. MMMM yyyy")
        return f
    }

    /// Short date for the recorded-line in the hero card. Compact —
    /// drops the weekday so the row stays one line beside the icon.
    static func heroDayShort() -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        f.setLocalizedDateFormatFromTemplate("d. MMMM yyyy")
        return f
    }

    /// "21:14" — bare 24h HH:mm. Locale-agnostic.
    static let heroTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Diary-day formatter — same shape as `heroDay`. Spelled out fully
    /// so the diary date always reads in absolute terms ("Today" /
    /// "Heute" would be ambiguous on the hero card).
    static func diaryDay() -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.shared.locale
        f.setLocalizedDateFormatFromTemplate("EEEE, d. MMMM yyyy")
        return f
    }

    // MARK: - Notes data

    /// Notes folded into this walkthrough. Driven by
    /// `manifest.drive_by_seeds_surfaced`, joined against the live list of
    /// note directories on disk. Rendered by `notesSection`.
    private func surfacedNoteEntries() -> [SurfacedNoteEntry] {
        guard case .walkthrough(let w) = item,
              let manifest = w.manifest,
              !manifest.drive_by_seeds_surfaced.isEmpty
        else { return [] }
        let order = manifest.drive_by_seeds_surfaced
        let allSeeds = SessionHistoryStore.loadVoiceNotes()
        let bySeedID = Dictionary(uniqueKeysWithValues: allSeeds.map {
            ($0.note.seed_id, $0)
        })
        return order.compactMap { noteID -> SurfacedNoteEntry? in
            guard let entry = bySeedID[noteID] else { return nil }
            let url = entry.directory.appending(path: "audio.m4a")
            return SurfacedNoteEntry(note: entry.note, audioURL: url)
        }
    }

    // MARK: - Sections data

    /// Build the descriptors driving the sections list. Walkthrough:
    /// one descriptor per manifest segment, with the per-segment server
    /// status when available. Note: single descriptor.
    private func sectionDescriptors() -> [SegmentDescriptor] {
        switch item {
        case .walkthrough(let w):
            guard let manifest = w.manifest else {
                // Manifest snapshot missing — fall back to plain segment
                // URLs so playback still works even if labels are bare.
                return w.segmentURLs.enumerated().map { idx, url in
                    SegmentDescriptor(
                        id: url.lastPathComponent,
                        title: String(localized: "Section \(idx + 1)"),
                        subtitle: nil,
                        transcript: "",
                        language: nil,
                        audioURL: url,
                        serverStatus: nil
                    )
                }
            }
            // segment_id (e.g. "s01") → server status
            let statusBySegmentID: [String: String] = Dictionary(
                uniqueKeysWithValues: (serverStatus?.segments ?? []).map {
                    ($0.segment_id, $0.status)
                }
            )
            // audio_file leaf ("s01.m4a") → on-disk URL
            let urlByLeaf: [String: URL] = Dictionary(
                uniqueKeysWithValues: w.segmentURLs.map { ($0.lastPathComponent, $0) }
            )
            return manifest.segments.map { seg -> SegmentDescriptor in
                let leaf = (seg.audioFile as NSString).lastPathComponent
                let url = urlByLeaf[leaf]
                let title: String
                let subtitle: String?
                let transcript: String
                let language: String?
                switch seg {
                case .calendarEvent(let ce):
                    title = ce.calendar_ref.title.isEmpty
                          ? String(localized: "Event")
                          : ce.calendar_ref.title
                    subtitle = Self.formatTimeRange(start: ce.calendar_ref.start, end: ce.calendar_ref.end)
                    transcript = ce.transcript
                    language = ce.language
                case .freeReflection(let fr):
                    title = String(localized: "Free reflection")
                    subtitle = nil
                    transcript = fr.transcript
                    language = fr.language
                case .voiceNote(let db):
                    title = String(localized: "Note")
                    subtitle = nil
                    transcript = db.transcript
                    language = db.language
                case .emptyBlock(let eb):
                    title = String(localized: "Empty block")
                    subtitle = Self.formatTimeRange(start: eb.time_range.start, end: eb.time_range.end)
                    transcript = eb.transcript
                    language = eb.language
                case .generalSection(let gs):
                    title = gs.title.isEmpty ? String(localized: "Section") : gs.title
                    subtitle = gs.prompt_text.isEmpty ? nil : gs.prompt_text
                    transcript = gs.transcript
                    language = gs.language
                }
                return SegmentDescriptor(
                    id: seg.audioFile,
                    title: title,
                    subtitle: subtitle,
                    transcript: transcript,
                    language: language,
                    audioURL: url,
                    serverStatus: serverStatusFetched
                        ? (statusBySegmentID[segmentIDFor(segment: seg)] ?? "unknown")
                        : nil
                )
            }
        case .voiceNote(let d):
            let url = d.directory.appending(path: "audio.m4a")
            return [SegmentDescriptor(
                id: d.note.id,
                title: String(localized: "Note recording"),
                subtitle: nil,
                transcript: d.note.transcript,
                language: d.note.language,
                audioURL: url,
                serverStatus: nil,
                durationSeconds: d.note.duration_seconds
            )]
        }
    }

    private func segmentIDFor(segment: Segment) -> String {
        switch segment {
        case .calendarEvent(let v):  return v.segment_id
        case .voiceNote(let v):        return v.segment_id
        case .freeReflection(let v): return v.segment_id
        case .emptyBlock(let v):     return v.segment_id
        case .generalSection(let v): return v.segment_id
        }
    }

    /// "09:00 – 09:30" from two ISO8601 timestamps. Returns `nil` on
    /// parse failure rather than rendering garbage.
    private static func formatTimeRange(start: String, end: String) -> String? {
        guard let s = ISO8601DateFormatter().date(from: start),
              let e = ISO8601DateFormatter().date(from: end) else {
            return nil
        }
        // HH:mm is locale-agnostic; using POSIX avoids the German
        // formatter forcing 24h on an EN system anyway.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "\(f.string(from: s)) – \(f.string(from: e))"
    }

    private func prepareAndShare() {
        prepareError = nil
        isPreparing = true
        Task {
            do {
                switch item {
                case .voiceNote(let d):
                    // Note audio sits in Application Support under a
                    // directory whose name is an ISO timestamp with
                    // colons — both of which break iOS's share sheet
                    // (LaunchServices error -10814, "no file-provider
                    // domain"). Stage it in tmp/ with a colon-free name
                    // first.
                    let src = d.directory.appending(path: "audio.m4a")
                    shareURL = try Self.stageInTempForSharing(
                        sourceURL: src,
                        baseName: "voicediary-note-\(Self.sanitize(d.note.id))"
                    )
                case .walkthrough(let w):
                    // Combine all segments into one m4a in tmp/.
                    // Prepend a short TTS announcement of each event
                    // title so the playback gives context that wasn't
                    // recorded (the per-event opener is TTS-only and
                    // never hits the mic). Titles are pulled from the
                    // manifest snapshot; older sessions without a
                    // manifest fall back to plain concatenation.
                    let language = w.manifest?.locale_primary ?? "de-DE"
                    // A segment may have been swiped away in this view, so
                    // merge only files that still exist. Titles align 1:1
                    // with the full segment list — once any are missing we
                    // drop them and fall back to plain concatenation.
                    let existing = w.segmentURLs.filter {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    guard !existing.isEmpty else {
                        prepareError = "Keine Audiodateien mehr vorhanden."
                        isPreparing = false
                        return
                    }
                    let titles = existing.count == w.segmentURLs.count
                        ? Self.titlesForSegments(in: w)
                        : nil
                    let merged = try await AudioMerger.mergedTempFile(
                        for: w.sessionID,
                        segments: existing,
                        titles: titles,
                        titleLanguage: language
                    )
                    shareURL = merged
                }
                isPreparing = false
                showShare = true
            } catch {
                isPreparing = false
                prepareError = error.localizedDescription
            }
        }
    }

    /// Build the per-segment title list used by AudioMerger to splice
    /// short TTS announcements between recordings. The manifest stores
    /// segments by their on-disk audio path (e.g. "segments/s01.m4a"),
    /// so we match each segment URL by its last path component to find
    /// the right calendar-event title. `nil` entries → no announcement
    /// for that segment (e.g. closing free-reflection segments don't
    /// have a title).
    private static func titlesForSegments(in entry: SessionHistoryStore.WalkthroughEntry) -> [String?] {
        guard let manifest = entry.manifest else {
            return Array(repeating: nil, count: entry.segmentURLs.count)
        }
        // segment_id (e.g. "s01") → title
        var titlesByLeaf: [String: String] = [:]
        for segment in manifest.segments {
            if case .calendarEvent(let ev) = segment {
                let leaf = (ev.audio_file as NSString).lastPathComponent
                titlesByLeaf[leaf] = ev.calendar_ref.title
            }
        }
        return entry.segmentURLs.map { titlesByLeaf[$0.lastPathComponent] }
    }

    /// Copy a file from the app sandbox into the system temporary
    /// directory under a colon-free filename, AND drop iOS data
    /// protection so the share-sheet extension (running in a separate
    /// process) can actually read it. Files that inherit
    /// `.completeFileProtection` from Application Support produce a
    /// silent "Speichern fehlgeschlagen" / "Öffnen fehlgeschlagen" in
    /// the share sheet because the receiving extension can't open
    /// them while the owning process holds them open.
    private static func stageInTempForSharing(sourceURL: URL, baseName: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "\(baseName).m4a")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        // Read into memory + write with .noFileProtection so the new
        // file is readable by other processes (Files, Mail, etc.).
        // copyItem would inherit the source's protection class and
        // re-introduce the bug.
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: dest, options: [.atomic, .noFileProtection])
        try? (dest as NSURL).setResourceValue(URLFileProtection.none,
                                              forKey: .fileProtectionKey)
        return dest
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "-")
         .replacingOccurrences(of: "+", with: "_")
         .replacingOccurrences(of: "/", with: "-")
    }

}

// MARK: - Stat tile

private struct StatTile: View {
    struct Model: Identifiable {
        let value: String
        let label: String
        var id: String { label }
    }
    let model: Model

    var body: some View {
        VStack(spacing: 4) {
            Text(model.value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.color.text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
            Text(model.label)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }
}

// MARK: - Playback scrubber

/// Voice-memo-style transport for the active row: a draggable knob on a
/// track plus elapsed / total time labels. Reads the live position from
/// the shared `SegmentPlayer`; tap or drag anywhere on the track seeks.
/// Only the active row mounts one, so only it re-renders on each tick.
struct PlaybackScrubber: View {
    let player: SegmentPlayer
    let tint: Color

    /// Knob position as a 0…1 fraction while the user is dragging; `nil`
    /// when not dragging, so the view follows the player instead.
    @State private var dragFraction: Double?

    private let knob: CGFloat = 14
    private let trackHeight: CGFloat = 4

    var body: some View {
        let duration = player.duration
        let positionFraction = dragFraction
            ?? (duration > 0 ? player.currentTime / duration : 0)
        let fraction = min(max(positionFraction, 0), 1)
        let displayTime = duration > 0 ? fraction * duration : 0

        VStack(spacing: 6) {
            GeometryReader { geo in
                let usable = max(geo.size.width - knob, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.color.border.subdued)
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(tint)
                        .frame(width: knob / 2 + usable * fraction, height: trackHeight)
                    Circle()
                        .fill(tint)
                        .frame(width: knob, height: knob)
                        .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                        .offset(x: usable * fraction)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // First change event of this drag → pause so
                            // playback doesn't run on while the user scrubs.
                            if dragFraction == nil { player.beginScrubbing() }
                            dragFraction = fractionFor(x: value.location.x, usable: usable)
                        }
                        .onEnded { value in
                            let f = fractionFor(x: value.location.x, usable: usable)
                            dragFraction = nil
                            player.endScrubbing(to: f * duration)
                        }
                )
            }
            .frame(height: max(knob, 24))

            HStack {
                Text(SegmentPlayer.formatDuration(displayTime))
                Spacer()
                Text(SegmentPlayer.formatDuration(duration))
            }
            .font(Theme.font.caption)
            .foregroundStyle(Theme.color.text.subdued)
            .monospacedDigit()
        }
        // A zero-length file can't be scrubbed; keep the row inert.
        .disabled(duration <= 0)
    }

    private func fractionFor(x: CGFloat, usable: CGFloat) -> Double {
        Double(min(max((x - knob / 2) / usable, 0), 1))
    }
}

// MARK: - Segment row

struct SegmentDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let transcript: String
    let language: String?
    let audioURL: URL?
    /// Server-side processing status: "processed" / "failed" /
    /// "pending_analysis" / "unknown" (server returned 404, so the
    /// in-memory status was lost). `nil` while the lookup is in flight
    /// or doesn't apply (note detail).
    let serverStatus: String?
    /// Audio length when it's known without decoding — notes carry
    /// `duration_seconds` in their metadata. `nil` for walkthrough
    /// segments, which the row loads lazily from the file instead.
    var durationSeconds: TimeInterval? = nil
}

private struct SegmentRow: View {
    let descriptor: SegmentDescriptor
    let player: SegmentPlayer

    @State private var duration: TimeInterval?

    private var isActive: Bool {
        descriptor.audioURL != nil && player.activeURL == descriptor.audioURL
    }
    private var isPlaying: Bool { isActive && player.isPlaying }

    /// "09:00 – 09:30 · 1:24 · DE" — time range · audio length · language,
    /// each part included only when available. Length comes from the
    /// descriptor when known (notes), else from the lazily-loaded value.
    private var metaText: String {
        var parts: [String] = []
        if let s = descriptor.subtitle, !s.isEmpty { parts.append(s) }
        if let d = descriptor.durationSeconds ?? duration, d > 0 {
            parts.append(SegmentPlayer.formatDuration(d))
        }
        if let l = descriptor.language, !l.isEmpty {
            parts.append(String(l.prefix(2)).uppercased())
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(alignment: .top, spacing: Theme.spacing.sm) {
                playButton

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .font(Theme.font.body.weight(.medium))
                        .foregroundStyle(Theme.color.text.primary)
                        .lineLimit(2)
                    // Metadata line — time range · audio length · language.
                    // Length stays visible even while playing (it's the
                    // clip length the user wants at a glance); the
                    // scrubber's total just mirrors it.
                    if !metaText.isEmpty {
                        Text(metaText)
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: Theme.spacing.xs)

                if let status = descriptor.serverStatus {
                    statusPill(for: status)
                }
            }

            if isActive {
                PlaybackScrubber(player: player, tint: Theme.color.text.link)
            }

            if !descriptor.transcript.isEmpty {
                Text(firstTwoLines(of: descriptor.transcript))
                    .font(Theme.font.callout)
                    .foregroundStyle(Theme.color.text.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: descriptor.audioURL?.path) {
            // Notes already carry their length in the descriptor; only
            // walkthrough segments need the lazy probe from the file.
            guard descriptor.durationSeconds == nil,
                  let url = descriptor.audioURL else { return }
            duration = await SegmentPlayer.duration(of: url)
        }
    }

    private var playButton: some View {
        Button {
            if let url = descriptor.audioURL { player.toggle(url: url) }
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.color.tint.link10)
                    .frame(width: 36, height: 36)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.color.text.link)
                    // Nudge the play glyph rightward to look optically
                    // centred inside the disc.
                    .offset(x: isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(descriptor.audioURL == nil)
        .opacity(descriptor.audioURL == nil ? 0.4 : 1)
        .accessibilityLabel(isPlaying ? "Pause" : "Abspielen")
    }

    private func statusPill(for status: String) -> some View {
        let label: String
        let bg: Color
        let fg: Color
        switch status {
        case "processed":
            label = "Verarbeitet"
            bg = Theme.color.tint.success10
            fg = Theme.color.status.success
        case "pending_analysis":
            label = "Wird verarbeitet"
            bg = Theme.color.tint.warning10
            fg = Theme.color.status.warning
        case "failed":
            label = "Fehlgeschlagen"
            bg = Theme.color.tint.destructive10
            fg = Theme.color.status.destructive
        default:
            label = "Unbekannt"
            bg = Theme.color.bg.containerInset
            fg = Theme.color.text.subdued
        }
        return Text(label)
            .font(Theme.font.caption.weight(.medium))
            .foregroundStyle(fg)
            .padding(.horizontal, Theme.spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous).fill(bg)
            )
            .fixedSize(horizontal: true, vertical: false)
    }

    private func firstTwoLines(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split on hard newlines first; if it's one paragraph, just let
        // SwiftUI's lineLimit(2) handle truncation visually.
        let lines = trimmed.split(separator: "\n", maxSplits: 2,
                                  omittingEmptySubsequences: true)
        if lines.count >= 2 {
            return lines.prefix(2).joined(separator: "\n")
        }
        return trimmed
    }
}

// MARK: - Note row

struct SurfacedNoteEntry: Sendable {
    let note: VoiceNote
    let audioURL: URL
}

/// One note surfaced into a walkthrough. Visually mirrors
/// `SegmentRow` (play button + meta + transcript preview) but sourced
/// from a `VoiceNote` rather than a manifest segment, and labelled
/// with the note's capture time instead of an event title.
private struct NoteRow: View {
    let entry: SurfacedNoteEntry
    let player: SegmentPlayer

    private var isActive: Bool { player.activeURL == entry.audioURL }
    private var isPlaying: Bool { isActive && player.isPlaying }

    /// "1:24 · DE" — audio length · language. Length comes straight from
    /// the note's stored `duration_seconds` (no file probe needed).
    private var metaText: String {
        var parts: [String] = []
        let dur = entry.note.duration_seconds
        if dur > 0 { parts.append(SegmentPlayer.formatDuration(dur)) }
        let l = entry.note.language
        if !l.isEmpty { parts.append(String(l.prefix(2)).uppercased()) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(alignment: .top, spacing: Theme.spacing.sm) {
                Button {
                    player.toggle(url: entry.audioURL)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.color.tint.warning10)
                            .frame(width: 36, height: 36)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.color.status.warning)
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(timeText)
                        .font(Theme.font.body.weight(.medium))
                        .foregroundStyle(Theme.color.text.primary)
                        .monospacedDigit()
                    // Audio length · language, always shown.
                    if !metaText.isEmpty {
                        Text(metaText)
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: Theme.spacing.xs)
            }

            if isActive {
                PlaybackScrubber(player: player, tint: Theme.color.status.warning)
            }

            if !entry.note.transcript.isEmpty {
                Text(entry.note.transcript)
                    .font(Theme.font.callout)
                    .foregroundStyle(Theme.color.text.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: entry.note.captured_at)
    }
}

// MARK: - UIActivityViewController bridge

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Plain URL passing — NSItemProvider wrapping was tried but
        // hid the filename in the sheet preview without solving the
        // multi-segment LaunchServices error. The real fix lives in
        // AudioMerger, which now produces files in the same on-disk
        // format as the working single-segment fast path.
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
