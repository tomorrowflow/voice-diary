import SwiftUI

/// "Gefahrenzone" — local-data management. Everything here is bulk and
/// destructive (per-item deletion lives on the Verlauf detail page):
///
///   * **Per-category swipe** — swipe a storage row left to delete *all*
///     sessions, *all* notes, or the *entire* upload queue at once. Each
///     swipe asks for confirmation first.
///   * **Älter als 30 Tage entfernen** — removes sessions + seeds whose
///     capture date is before the cutoff. Queued sessions are skipped so
///     an in-flight upload isn't orphaned.
///   * **Alle lokalen Daten löschen** — wipes both audio directories, the
///     surfaced-seed index, and the upload queue.
///
/// Server-side data (LightRAG, Postgres, the diary entries themselves)
/// is **not** touched by anything on this screen.

/// A swipeable storage category. Drives both the rows and the
/// confirmation alert.
private enum Category: String, Identifiable {
    case sessions, notes, queue
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "Sitzungen"
        case .notes:    return "Notizen"
        case .queue:    return "Upload-Queue"
        }
    }
    var icon: String {
        switch self {
        case .sessions: return "calendar.day.timeline.left"
        case .notes:    return "waveform"
        case .queue:    return "arrow.up.circle"
        }
    }
    func count(_ s: SessionHistoryStore.StorageSnapshot) -> Int {
        switch self {
        case .sessions: return s.walkthroughs.count
        case .notes:    return s.driveBys.count
        case .queue:    return s.queueCount
        }
    }
    func bytes(_ s: SessionHistoryStore.StorageSnapshot) -> Int64 {
        switch self {
        case .sessions: return s.walkthroughs.totalBytes
        case .notes:    return s.driveBys.totalBytes
        case .queue:    return s.queueBytes
        }
    }
    var confirmTitle: String {
        switch self {
        case .sessions: return "Alle Sitzungen löschen?"
        case .notes:    return "Alle Notizen löschen?"
        case .queue:    return "Upload-Queue leeren?"
        }
    }
    func confirmMessage(count: Int) -> String {
        switch self {
        case .sessions:
            return "\(count) Sitzung(en) werden vom Gerät entfernt. Server-Daten bleiben unberührt. Diese Aktion kann nicht rückgängig gemacht werden."
        case .notes:
            return "\(count) Notiz(en) werden vom Gerät entfernt. Server-Daten bleiben unberührt. Diese Aktion kann nicht rückgängig gemacht werden."
        case .queue:
            return "\(count) ausstehende(r) Upload(s) werden abgebrochen. Die zugehörigen Aufnahmen bleiben unter Sitzungen / Notizen erhalten."
        }
    }
}

/// Identifies which destructive action the user has tapped but not yet
/// confirmed. Drives a single `.alert` modifier — stacking two `.alert`
/// modifiers on the same view is a long-standing SwiftUI gotcha (the
/// second shadows the first).
private enum PendingDeletion: Identifiable {
    case category(Category)
    case partial
    case nuke
    var id: String {
        switch self {
        case .category(let c): return "cat:" + c.rawValue
        case .partial:         return "partial"
        case .nuke:            return "nuke"
        }
    }
}

@MainActor
public struct DangerZoneView: View {
    @State private var snapshot: SessionHistoryStore.StorageSnapshot?
    @State private var queueCount: Int = 0
    @State private var queuedSessionIDs: Set<String> = []
    @State private var isWorking: Bool = false
    @State private var infoMessage: String?
    @State private var pendingDeletion: PendingDeletion?

    /// 30-day cutoff matches SPEC §13.2's "1 month" default for raw
    /// audio retention. Computed at view-init time so the same instant
    /// drives the snapshot scan + the actual delete call.
    private let cutoff: Date = {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    }()

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Gefahrenzone")

                List {
                    cardRow { scopeCard }

                    Section {
                        ForEach([Category.sessions, .notes, .queue]) { cat in
                            categoryRow(cat)
                        }
                        totalRow
                    } header: {
                        Text("Speicher · nach links wischen zum Löschen")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                            .textCase(nil)
                    }

                    cardRow { partialDeleteCard }
                    cardRow { nukeCard }

                    if let infoMessage {
                        cardRow { infoCard(infoMessage) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
        // `.onAppear` (not `.task`) so the counts re-scan when the user
        // returns to the screen after a delete elsewhere.
        .onAppear { Task { await refresh() } }
        // Single alert driven by `pendingDeletion`. Title + message vary
        // per case so the user sees what's about to be removed *before*
        // the destructive button is enabled.
        .alert(
            alertTitle,
            isPresented: alertIsPresentedBinding,
            presenting: pendingDeletion
        ) { action in
            Button("Abbrechen", role: .cancel) {
                pendingDeletion = nil
            }
            Button("Endgültig löschen", role: .destructive) {
                Task {
                    switch action {
                    case .category(let c): await runCategory(c)
                    case .partial:         await runPartial()
                    case .nuke:            await runNuke()
                    }
                    pendingDeletion = nil
                }
            }
        } message: { action in
            Text(alertMessage(for: action))
        }
    }

    // MARK: - Alert wiring

    /// SwiftUI's `.alert(_:isPresented:presenting:…)` form needs a `Bool`
    /// binding alongside the value. Map the optional enum to a bool so
    /// the alert closes when either button is tapped.
    private var alertIsPresentedBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { newValue in
                if !newValue { pendingDeletion = nil }
            }
        )
    }

    private var alertTitle: String {
        switch pendingDeletion {
        case .category(let c): return c.confirmTitle
        case .partial:         return "Älter als 30 Tage entfernen?"
        case .nuke:            return "Alle lokalen Daten löschen?"
        case .none:            return ""
        }
    }

    private func alertMessage(for action: PendingDeletion) -> String {
        switch action {
        case .category(let c):
            let count = snapshot.map(c.count) ?? 0
            return c.confirmMessage(count: count)
        case .partial:
            return partialAlertMessage
        case .nuke:
            if queueCount > 0 {
                return "Sitzungen, Notizen, der Surfaced-Index und \(queueCount) Upload-Queue-Eintrag/-Einträge werden vom Gerät entfernt. Server-Daten bleiben unberührt. Diese Aktion kann nicht rückgängig gemacht werden."
            }
            return "Sitzungen, Notizen und der Surfaced-Index werden vom Gerät entfernt. Server-Daten bleiben unberührt. Diese Aktion kann nicht rückgängig gemacht werden."
        }
    }

    // MARK: - Rows

    /// Wrap a card view as a chrome-free list row so the existing card
    /// styling survives the move from `ScrollView` to `List`.
    @ViewBuilder
    private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: Theme.spacing.md,
                                      bottom: 6, trailing: Theme.spacing.md))
    }

    /// One storage category, swipe-left to bulk-delete (with a
    /// confirmation alert). The swipe button is omitted when the category
    /// is already empty, and full-swipe is disabled so a stray gesture
    /// can't wipe a whole category without the deliberate tap + confirm.
    private func categoryRow(_ cat: Category) -> some View {
        let count = snapshot.map(cat.count) ?? 0
        let bytes = snapshot.map(cat.bytes) ?? 0
        return HStack(spacing: Theme.spacing.sm) {
            Image(systemName: cat.icon)
                .font(.body)
                .foregroundStyle(Theme.color.text.secondary)
                .frame(width: 26)
            Text(cat.title)
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
            Text("\(count)")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .monospacedDigit()
            Text(byteFormatter.string(fromByteCount: bytes))
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.subdued)
                .monospacedDigit()
        }
        .listRowBackground(Theme.color.bg.surface)
        .listRowInsets(EdgeInsets(top: 12, leading: Theme.spacing.md,
                                  bottom: 12, trailing: Theme.spacing.md))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if count > 0 && !isWorking {
                Button(role: .destructive) {
                    pendingDeletion = .category(cat)
                } label: {
                    Label("Alle löschen", systemImage: "trash")
                }
            }
        }
    }

    private var totalRow: some View {
        HStack {
            Text("Gesamt")
                .font(Theme.font.body.weight(.semibold))
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
            Text(byteFormatter.string(fromByteCount: snapshot?.totalBytes ?? 0))
                .font(Theme.font.monoBody.weight(.semibold))
                .foregroundStyle(Theme.color.text.primary)
                .monospacedDigit()
        }
        .listRowBackground(Theme.color.bg.surface)
        .listRowInsets(EdgeInsets(top: 12, leading: Theme.spacing.md,
                                  bottom: 12, trailing: Theme.spacing.md))
    }

    // MARK: - Cards

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.color.status.warning)
                    .frame(width: 28)
                Text("Lokale Daten")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }
            Text("Diese Aktionen entfernen ausschließlich Daten auf diesem iPhone (Audio-Aufnahmen, Notizen, Upload-Queue). Tagebucheinträge auf deinem Server bleiben erhalten. Einzelne Einträge löschst du im Verlauf.")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private var partialDeleteCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "calendar.badge.minus")
                    .font(.title3)
                    .foregroundStyle(Theme.color.status.warning)
                    .frame(width: 28)
                Text("Älter als 30 Tage")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }
            Text(partialDescription)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                pendingDeletion = .partial
            } label: {
                Label("Älter als 30 Tage entfernen", systemImage: "trash")
            }
            .buttonStyle(.dsDestructive(size: .md, fullWidth: true))
            .disabled(isWorking || partialIsEmpty)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private var nukeCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "flame.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.color.status.destructive)
                    .frame(width: 28)
                Text("Alle lokalen Daten")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }
            Text(nukeDescription)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                pendingDeletion = .nuke
            } label: {
                Label("Alle lokalen Daten löschen", systemImage: "trash.fill")
            }
            .buttonStyle(.dsDestructive(size: .md, fullWidth: true))
            .disabled(isWorking || allEmpty)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private var nukeDescription: String {
        if queueCount > 0 {
            return "Entfernt alle Sitzungen, Notizen, den Surfaced-Index und \(queueCount) Eintrag/Einträge aus der Upload-Queue. Server-Daten bleiben unberührt."
        }
        return "Entfernt alle Sitzungen, Notizen und den Surfaced-Index vom Gerät. Server-Daten bleiben unberührt."
    }

    private func infoCard(_ message: String) -> some View {
        HStack(spacing: Theme.spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.color.status.success)
            Text(message)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.status.success.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.status.success.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Logic

    private func refresh() async {
        let cutoffSnapshot = cutoff
        let snap = await Task.detached(priority: .userInitiated) {
            SessionHistoryStore.storageSnapshot(olderThan: cutoffSnapshot)
        }.value
        let pending = await SessionUploader.shared.pending()
        snapshot = snap
        queueCount = pending.count
        queuedSessionIDs = Set(pending.map(\.id))
    }

    private func runCategory(_ cat: Category) async {
        isWorking = true
        defer { isWorking = false }
        switch cat {
        case .sessions:
            let freed = await Task.detached(priority: .userInitiated) {
                SessionHistoryStore.deleteAllWalkthroughs()
            }.value
            _ = await SessionUploader.shared.purgeOrphans()
            infoMessage = "\(byteFormatter.string(fromByteCount: freed)) wurden freigegeben."
        case .notes:
            let freed = await Task.detached(priority: .userInitiated) {
                SessionHistoryStore.deleteAllDriveBys()
            }.value
            _ = await SessionUploader.shared.purgeOrphans()
            infoMessage = "\(byteFormatter.string(fromByteCount: freed)) wurden freigegeben."
        case .queue:
            await SessionUploader.shared.clear()
            infoMessage = "Upload-Queue geleert."
        }
        await refresh()
    }

    private func runPartial() async {
        isWorking = true
        defer { isWorking = false }
        let queuedIDs = queuedSessionIDs
        let cutoffSnapshot = cutoff
        let freed = await Task.detached(priority: .userInitiated) {
            SessionHistoryStore.deleteOlderThan(cutoffSnapshot, queuedSessionIDs: queuedIDs)
        }.value
        _ = await SessionUploader.shared.purgeOrphans()
        infoMessage = "\(byteFormatter.string(fromByteCount: freed)) wurden freigegeben."
        await refresh()
    }

    private func runNuke() async {
        isWorking = true
        defer { isWorking = false }
        // Clear the in-memory queue first so the uploader actor doesn't
        // re-persist `upload_queue.json` after we've removed it from
        // disk. `clear()` also writes an empty array back, which
        // `deleteAllLocalAudio` then unlinks alongside the audio dirs.
        await SessionUploader.shared.clear()
        let freed = await Task.detached(priority: .userInitiated) {
            SessionHistoryStore.deleteAllLocalAudio()
        }.value
        infoMessage = "\(byteFormatter.string(fromByteCount: freed)) wurden freigegeben."
        await refresh()
    }

    // MARK: - Derived

    private var partialIsEmpty: Bool {
        (snapshot?.olderThanCutoff.count ?? 0) == 0
    }

    private var allEmpty: Bool {
        guard let snap = snapshot else { return true }
        return snap.walkthroughs.count == 0 && snap.driveBys.count == 0
    }

    private var partialDescription: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM yyyy"
        let cutoffLabel = f.string(from: cutoff)
        guard let snap = snapshot else {
            return "Entfernt Sitzungen und Notizen, die vor dem \(cutoffLabel) aufgenommen wurden. Einträge in der Upload-Queue werden übersprungen."
        }
        let count = snap.olderThanCutoff.count
        let bytes = byteFormatter.string(fromByteCount: snap.olderThanCutoff.totalBytes)
        if count == 0 {
            return "Nichts älter als der \(cutoffLabel) auf dem Gerät."
        }
        return "\(count) Eintrag/Einträge vor dem \(cutoffLabel) · \(bytes) werden entfernt. Einträge in der Upload-Queue werden übersprungen."
    }

    private var partialAlertMessage: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM yyyy"
        let cutoffLabel = f.string(from: cutoff)
        guard let snap = snapshot, snap.olderThanCutoff.count > 0 else {
            return "Aktion abgebrochen — nichts älter als der \(cutoffLabel) vorhanden."
        }
        let bytes = byteFormatter.string(fromByteCount: snap.olderThanCutoff.totalBytes)
        return "\(snap.olderThanCutoff.count) Eintrag/Einträge vor dem \(cutoffLabel) (\(bytes)) werden entfernt. Diese Aktion kann nicht rückgängig gemacht werden."
    }

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.includesUnit = true
        f.includesCount = true
        return f
    }()
}
