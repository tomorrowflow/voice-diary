import SwiftUI
import UIKit

/// Local Verlauf — chronological list of recorded sessions (walkthrough
/// + drive-by) grouped by day. Tapping a row opens the detail view.
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
                FlowHeader(title: "Verlauf")

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
        .task { reload() }
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
                Label("Löschen", systemImage: "trash")
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
            Text("Noch keine Sitzungen")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text("Walkthrough- und Drive-by-Aufnahmen erscheinen hier.")
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
            deleteError = "Löschen fehlgeschlagen: \(error.localizedDescription)"
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
        if cal.isDateInToday(day) { return "Heute" }
        if cal.isDateInYesterday(day) { return "Gestern" }
        return Self.dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM"
        return f
    }()
}

// MARK: - Row

private struct VerlaufRow: View {
    let item: SessionHistoryStore.Item

    var body: some View {
        HStack(spacing: Theme.spacing.sm) {
            // Tinted icon disc — distinguishes walkthrough vs drive-by
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
        case .driveBy:     return "mic.fill"
        }
    }

    private var iconBg: Color {
        switch item {
        case .walkthrough: return Theme.color.tint.link10
        case .driveBy:     return Theme.color.tint.warning10
        }
    }

    private var iconFg: Color {
        switch item {
        case .walkthrough: return Theme.color.text.link
        case .driveBy:     return Theme.color.status.warning
        }
    }

    private var title: String {
        switch item {
        case .walkthrough(let w):
            switch w.eventCount {
            case 0: return "Abend-Sitzung"
            case 1: return "Abend-Sitzung · 1 Termin"
            default: return "Abend-Sitzung · \(w.eventCount) Termine"
            }
        case .driveBy(let d):
            let preview = d.seed.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Drive-by" : preview
        }
    }

    /// Subtitle is the **date the recording is for**. The list above is
    /// already grouped by capture day, so the row no longer restates
    /// when it was recorded — the second line is the *subject* day
    /// (manifest.date for walkthrough, captured_at for drive-by) so a
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
            return "Für " + Self.relativeDay.string(from: base)
        case .driveBy(let d):
            return "Für " + Self.relativeDay.string(from: d.seed.captured_at)
        }
    }

    /// "yyyy-MM-dd" parser for manifest.date.
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Heute" / "Gestern" / "Mittwoch, 30. April".
    static let relativeDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()
}

// MARK: - Detail

@MainActor
struct VerlaufDetailView: View {
    let item: SessionHistoryStore.Item

    @State private var shareURL: URL?
    @State private var isPreparing: Bool = false
    @State private var prepareError: String?
    @State private var showShare: Bool = false
    @State private var serverStatus: ServerClient.SessionStatusResponse?
    @State private var serverStatusFetched: Bool = false
    @StateObject private var player = SegmentPlayer()

    var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: title)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing.lg) {
                        heroCard
                        statsGrid

                        sectionsList

                        identifierFooter

                        if let prepareError {
                            Text(prepareError)
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.status.destructive)
                                .padding(.horizontal, Theme.spacing.md)
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.top, Theme.spacing.md)
                    .padding(.bottom, 200)
                }
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
                                Text("Audio wird vorbereitet…")
                            }
                        } else {
                            Label("Audio teilen", systemImage: "square.and.arrow.up")
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

    private func loadServerStatus() async {
        guard !serverStatusFetched else { return }
        serverStatusFetched = true
        let sessionID: String
        switch item {
        case .walkthrough(let w): sessionID = w.sessionID
        case .driveBy:            return  // drive-by seeds upload as part of a session, no per-seed status
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
        case .walkthrough: return "Abend"
        case .driveBy:     return "Drive-by"
        }
    }

    // MARK: - Composition

    /// Hero header: tinted icon disc + "aufgenommen: <date>, <time>"
    /// beside it. Walkthroughs add a "Tagebucheintrag:" block below.
    /// The session type (Abend / Drive-by) already lives in the page
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
        case .driveBy(let d):
            icon = "mic.fill"
            iconBg = Theme.color.tint.warning10
            iconFg = Theme.color.status.warning
            captured = d.seed.captured_at
            diaryDate = nil
        }
        let recordedLine = Self.heroDayShort.string(from: captured)
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
                    Text("Tagebucheintrag:")
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                    Text(Self.diaryDay.string(from: diaryDate))
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
                .init(value: "\(w.eventCount)",      label: "Termine"),
                .init(value: "\(w.segmentURLs.count)", label: "Segmente"),
                .init(value: String(format: "%.1f MB", totalMB), label: "Größe"),
            ]
        case .driveBy(let d):
            let bytes = (try? d.directory.appending(path: "audio.m4a")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let kb = Double(bytes) / 1_000
            tiles = [
                .init(value: String(format: "%.0f", d.seed.duration_seconds.rounded()) + " s",
                      label: "Dauer"),
                .init(value: d.seed.language.uppercased(), label: "Sprache"),
                .init(value: String(format: "%.0f KB", kb), label: "Größe"),
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
        case .driveBy(let d):
            label = "SEED-ID"
            value = d.seed.id
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

    static let heroDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    /// "Freitag, 1. Mai 2026" — full date, no time, no relative
    /// shortcuts ("Heute"). Kept distinct from the section list's
    /// time-of-day formatting so it reads as a calendar marker.
    static let heroDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.setLocalizedDateFormatFromTemplate("EEEE, d. MMMM yyyy")
        return f
    }()

    /// "3. Mai 2026" — no weekday, used for the recorded line in the
    /// hero card so the row stays compact next to the icon.
    static let heroDayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.setLocalizedDateFormatFromTemplate("d. MMMM yyyy")
        return f
    }()

    /// "21:14" — bare HH:mm.
    static let heroTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Diary-day formatter for the hero card. Same shape as `heroDay` —
    /// the user explicitly asked for "Freitag, 1. Mai 2026" with no
    /// relative shortcut so the diary day always reads in absolute terms.
    static let diaryDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.setLocalizedDateFormatFromTemplate("EEEE, d. MMMM yyyy")
        return f
    }()

    // MARK: - Sections list

    /// Per-segment list with play button, duration, first two transcript
    /// lines, and the server-side processing status. For walkthrough
    /// sessions we walk the manifest's segments so the labels carry the
    /// calendar-event titles. For drive-by we render a single row.
    @ViewBuilder
    private var sectionsList: some View {
        let descriptors = sectionDescriptors()
        if descriptors.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.spacing.sm) {
                Text("ABSCHNITTE")
                    .font(Theme.font.monoCaption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .tracking(0.5)
                    .padding(.horizontal, Theme.spacing.xs)

                VStack(spacing: Theme.spacing.sm) {
                    ForEach(descriptors) { d in
                        SegmentRow(
                            descriptor: d,
                            isPlaying: player.playingURL == d.audioURL,
                            onTogglePlay: {
                                if let url = d.audioURL { player.toggle(url: url) }
                            }
                        )
                    }
                }
            }
        }
    }

    /// Build the descriptors driving the sections list. Walkthrough:
    /// one descriptor per manifest segment, with the per-segment server
    /// status when available. Drive-by: single descriptor.
    private func sectionDescriptors() -> [SegmentDescriptor] {
        switch item {
        case .walkthrough(let w):
            guard let manifest = w.manifest else {
                // Manifest snapshot missing — fall back to plain segment
                // URLs so playback still works even if labels are bare.
                return w.segmentURLs.enumerated().map { idx, url in
                    SegmentDescriptor(
                        id: url.lastPathComponent,
                        title: "Abschnitt \(idx + 1)",
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
                    title = ce.calendar_ref.title.isEmpty ? "Termin" : ce.calendar_ref.title
                    subtitle = Self.formatTimeRange(start: ce.calendar_ref.start, end: ce.calendar_ref.end)
                    transcript = ce.transcript
                    language = ce.language
                case .freeReflection(let fr):
                    title = "Freie Reflexion"
                    subtitle = nil
                    transcript = fr.transcript
                    language = fr.language
                case .driveBy(let db):
                    title = "Drive-by"
                    subtitle = nil
                    transcript = db.transcript
                    language = db.language
                case .emptyBlock(let eb):
                    title = "Leerer Block"
                    subtitle = Self.formatTimeRange(start: eb.time_range.start, end: eb.time_range.end)
                    transcript = eb.transcript
                    language = eb.language
                case .generalSection(let gs):
                    title = gs.title.isEmpty ? "Abschnitt" : gs.title
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
        case .driveBy(let d):
            let url = d.directory.appending(path: "audio.m4a")
            return [SegmentDescriptor(
                id: d.seed.id,
                title: "Drive-by-Aufnahme",
                subtitle: nil,
                transcript: d.seed.transcript,
                language: d.seed.language,
                audioURL: url,
                serverStatus: nil
            )]
        }
    }

    private func segmentIDFor(segment: Segment) -> String {
        switch segment {
        case .calendarEvent(let v):  return v.segment_id
        case .driveBy(let v):        return v.segment_id
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return "\(f.string(from: s)) – \(f.string(from: e))"
    }

    private func prepareAndShare() {
        prepareError = nil
        isPreparing = true
        Task {
            do {
                switch item {
                case .driveBy(let d):
                    // Drive-by audio sits in Application Support under a
                    // directory whose name is an ISO timestamp with
                    // colons — both of which break iOS's share sheet
                    // (LaunchServices error -10814, "no file-provider
                    // domain"). Stage it in tmp/ with a colon-free name
                    // first.
                    let src = d.directory.appending(path: "audio.m4a")
                    shareURL = try Self.stageInTempForSharing(
                        sourceURL: src,
                        baseName: "voicediary-driveby-\(Self.sanitize(d.seed.id))"
                    )
                case .walkthrough(let w):
                    // Combine all segments into one m4a in tmp/.
                    // Prepend a short TTS announcement of each event
                    // title so the playback gives context that wasn't
                    // recorded (the per-event opener is TTS-only and
                    // never hits the mic). Titles are pulled from the
                    // manifest snapshot; older sessions without a
                    // manifest fall back to plain concatenation.
                    let titles = Self.titlesForSegments(in: w)
                    let language = w.manifest?.locale_primary ?? "de-DE"
                    let merged = try await AudioMerger.mergedTempFile(
                        for: w.sessionID,
                        segments: w.segmentURLs,
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
    /// or doesn't apply (drive-by detail).
    let serverStatus: String?
}

private struct SegmentRow: View {
    let descriptor: SegmentDescriptor
    let isPlaying: Bool
    let onTogglePlay: () -> Void

    @State private var duration: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(alignment: .top, spacing: Theme.spacing.sm) {
                playButton

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .font(Theme.font.body.weight(.medium))
                        .foregroundStyle(Theme.color.text.primary)
                        .lineLimit(2)
                    HStack(spacing: Theme.spacing.xs) {
                        if let subtitle = descriptor.subtitle {
                            Text(subtitle)
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.text.subdued)
                        }
                        if descriptor.subtitle != nil, duration != nil {
                            Text("·")
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.text.subdued)
                        }
                        if let duration {
                            Text(SegmentPlayer.formatDuration(duration))
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.text.subdued)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer(minLength: Theme.spacing.xs)

                if let status = descriptor.serverStatus {
                    statusPill(for: status)
                }
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
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
        .task(id: descriptor.audioURL?.path) {
            guard let url = descriptor.audioURL else { return }
            duration = await SegmentPlayer.duration(of: url)
        }
    }

    private var playButton: some View {
        Button(action: onTogglePlay) {
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
