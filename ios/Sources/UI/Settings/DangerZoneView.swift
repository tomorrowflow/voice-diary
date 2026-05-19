import SwiftUI

/// "Gefahrenzone" — local-data management. Shows per-category disk
/// usage and two destructive actions:
///
///   * **Älter als 30 Tage entfernen** — removes sessions + seeds
///     whose capture date is before the cutoff. Queued sessions are
///     skipped so an in-flight upload isn't orphaned.
///   * **Alle lokalen Daten löschen** — wipes both audio directories
///     and the surfaced-seed index. Refuses when the upload queue is
///     non-empty (the user has to flush first via Verlauf / queue
///     retry) so we never delete audio referenced by a pending upload.
///
/// Server-side data (LightRAG, Postgres, the diary entries themselves)
/// is **not** touched by anything on this screen.
/// Identifies which destructive action the user has tapped but not
/// yet confirmed. Used to drive a single `.alert` modifier — stacking
/// two `.alert` modifiers on the same view is a long-standing SwiftUI
/// gotcha (the second one shadows the first) which is why an earlier
/// version of this screen sometimes appeared to skip the confirmation
/// for one of the buttons.
private enum PendingDeletion: Identifiable {
    case partial
    case nuke
    var id: String {
        switch self {
        case .partial: return "partial"
        case .nuke:    return "nuke"
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

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        scopeCard
                        volumeCard
                        partialDeleteCard
                        nukeCard
                        if let infoMessage {
                            infoCard(infoMessage)
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .task { await refresh() }
        // Single alert driven by `pendingDeletion`. Title + message
        // vary per case so the user sees what's about to be removed
        // *before* the destructive button is enabled.
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
                    case .partial: await runPartial()
                    case .nuke:    await runNuke()
                    }
                    pendingDeletion = nil
                }
            }
        } message: { action in
            Text(alertMessage(for: action))
        }
    }

    // MARK: - Alert wiring

    /// SwiftUI's `.alert(_:isPresented:presenting:…)` form needs a
    /// `Bool` binding alongside the value. Map the optional enum to a
    /// bool so the alert closes when either button is tapped.
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
        case .partial: return "Älter als 30 Tage entfernen?"
        case .nuke:    return "Alle lokalen Daten löschen?"
        case .none:    return ""
        }
    }

    private func alertMessage(for action: PendingDeletion) -> String {
        switch action {
        case .partial:
            return partialAlertMessage
        case .nuke:
            if queueCount > 0 {
                return "Sitzungen, Notizen, der Surfaced-Index und \(queueCount) Upload-Queue-Eintrag/-Einträge werden vom Gerät entfernt. Server-Daten bleiben unberührt. Diese Aktion kann nicht rückgängig gemacht werden."
            }
            return "Sitzungen, Notizen und der Surfaced-Index werden vom Gerät entfernt. Server-Daten bleiben unberührt. Diese Aktion kann nicht rückgängig gemacht werden."
        }
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
            Text("Diese Aktionen entfernen ausschließlich Daten auf diesem iPhone (Audio-Aufnahmen, Notizen, Upload-Queue). Tagebucheinträge auf deinem Server bleiben erhalten.")
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

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: "internaldrive")
                    .font(.title3)
                    .foregroundStyle(Theme.color.text.primary)
                    .frame(width: 28)
                Text("Speicher-Übersicht")
                    .font(Theme.font.headline)
                    .foregroundStyle(Theme.color.text.primary)
                Spacer()
            }

            if let snap = snapshot {
                // Grid keeps the three columns (label / count / bytes)
                // aligned across rows. Without it, each HStack sizes
                // independently and the bytes column drifts whenever a
                // value crosses a digit boundary or wraps to a second
                // line.
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: Theme.spacing.sm,
                     verticalSpacing: Theme.spacing.sm) {
                    statRow(label: "Sitzungen",
                            count: snap.walkthroughs.count,
                            countLabel: "Sitzungen",
                            bytes: snap.walkthroughs.totalBytes)
                    GridRow {
                        Divider().background(Theme.color.border.subdued)
                            .gridCellColumns(3)
                    }
                    statRow(label: "Notizen",
                            count: snap.driveBys.count,
                            countLabel: "Stück",
                            bytes: snap.driveBys.totalBytes)
                    GridRow {
                        Divider().background(Theme.color.border.subdued)
                            .gridCellColumns(3)
                    }
                    statRow(label: "Upload-Queue",
                            count: snap.queueCount,
                            countLabel: "Einträge",
                            bytes: snap.queueBytes)
                    GridRow {
                        Divider().background(Theme.color.border.subdued)
                            .gridCellColumns(3)
                    }
                    GridRow {
                        Text("Gesamt")
                            .font(Theme.font.body.weight(.semibold))
                            .foregroundStyle(Theme.color.text.primary)
                        Color.clear.frame(height: 1)
                        Text(byteFormatter.string(fromByteCount: snap.totalBytes))
                            .font(Theme.font.monoBody.weight(.semibold))
                            .foregroundStyle(Theme.color.text.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
            } else {
                HStack(spacing: Theme.spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Wird berechnet…")
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                }
            }
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

    /// One row inside the `Grid` of the volume card. Returns a
    /// `GridRow` so the column widths stay consistent across rows.
    private func statRow(
        label: String,
        count: Int,
        countLabel: String,
        bytes: Int64
    ) -> some View {
        GridRow {
            Text(label)
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
                .gridColumnAlignment(.leading)
            Text("\(count) \(countLabel)")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .gridColumnAlignment(.trailing)
            Text(byteFormatter.string(fromByteCount: bytes))
                .font(Theme.font.monoBody)
                .foregroundStyle(Theme.color.text.primary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .gridColumnAlignment(.trailing)
        }
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
