import SwiftUI

/// Settings → More → Diagnostics.
///
/// Surfaces what `DiagnosticsCollector` has captured: crash / hang /
/// CPU / disk-write payloads from `MXMetricManager`, plus the OSLogStore
/// window that was frozen around each event. Read-only view; the only
/// mutating actions are "share bundle" and "delete".
///
/// Also lets the user pull a live tail of the app's own subsystem logs
/// from the last hour — useful when something felt off during a
/// recording but the app didn't crash.
@MainActor
public struct DiagnosticsView: View {
    @State private var reports: [DiagnosticsCollector.Report] = []
    @State private var recentLogs: [String] = []
    @State private var showRecentLogs: Bool = false
    @State private var confirmDeleteAll: Bool = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Diagnostics")

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing.md) {
                        introCard

                        crashesSection

                        recentLogsSection

                        if !reports.isEmpty {
                            Button(role: .destructive) {
                                confirmDeleteAll = true
                            } label: {
                                Text("Delete all reports")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.dsDestructive(size: .md))
                            .padding(.top, Theme.spacing.sm)
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { refresh() }
        .confirmationDialog(
            Text("Delete all reports?"),
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                DiagnosticsCollector.shared.deleteAll()
                refresh()
            } label: {
                Text("Delete permanently")
            }
            Button(role: .cancel) {} label: { Text("Cancel") }
        }
    }

    // --- sections ------------------------------------------------------

    private var introCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text("Crashes, hangs, and excessive resource use are captured on-device by MetricKit and surfaced here. No data leaves the phone.")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
            Text("Use the share button on a report to AirDrop / email the bundle to your Mac for symbolication in Xcode.")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color.bg.surfaceInset)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md))
    }

    private var crashesSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            sectionHeader("Crash reports", count: reports.count)

            if reports.isEmpty {
                Text("No reports stored. The system delivers them once per day, or at the next launch after a crash.")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .padding(.vertical, Theme.spacing.xs)
            } else {
                VStack(spacing: Theme.spacing.xs) {
                    ForEach(reports) { report in
                        NavigationLink {
                            DiagnosticsDetailView(report: report) {
                                refresh()
                            }
                        } label: {
                            reportRow(report)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentLogsSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            sectionHeader("Recent logs", count: nil)

            if !showRecentLogs {
                Button {
                    recentLogs = DiagnosticsCollector.shared.recentLogLines(hours: 1)
                    showRecentLogs = true
                } label: {
                    Text("Show last hour")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsOutline(size: .md))
            } else {
                if recentLogs.isEmpty {
                    Text("No entries in the last hour.")
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                } else {
                    HStack {
                        Text("\(recentLogs.count) entries")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                        Spacer()
                        ShareLink(item: recentLogs.joined(separator: "\n")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(Text("Share logs"))
                    }
                    ScrollView(.horizontal) {
                        Text(recentLogs.suffix(200).joined(separator: "\n"))
                            .font(Theme.font.monoCaption)
                            .textSelection(.enabled)
                            .padding(Theme.spacing.sm)
                    }
                    .frame(maxHeight: 320)
                    .background(Theme.color.bg.surfaceInset)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius.sm))
                }
            }
        }
    }

    // --- bits ----------------------------------------------------------

    private func sectionHeader(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack {
            Text(title)
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            if let count {
                Text("(\(count))")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
            Spacer()
        }
    }

    private func reportRow(_ report: DiagnosticsCollector.Report) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.summary)
                    .font(Theme.font.body)
                    .foregroundStyle(Theme.color.text.primary)
                Text(report.timestamp, format: .dateTime.year().month().day().hour().minute())
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.color.bg.surfaceInset)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md))
    }

    private func refresh() {
        reports = DiagnosticsCollector.shared.listReports()
    }
}

// MARK: - Detail view

@MainActor
private struct DiagnosticsDetailView: View {
    let report: DiagnosticsCollector.Report
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var logText: String = ""
    @State private var payloadText: String = ""

    var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(verbatim: report.summary)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing.md) {
                        HStack {
                            Text(report.timestamp, format: .dateTime
                                .year().month().day().hour().minute().second())
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.text.subdued)
                            Spacer()
                            ShareLink(item: DiagnosticsCollector.shared
                                .shareBundleText(for: report)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .labelStyle(.iconOnly)
                            }
                            Button(role: .destructive) {
                                DiagnosticsCollector.shared.delete(report)
                                onChange()
                                dismiss()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.color.status.destructive)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Delete report"))
                        }

                        if !logText.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                                Text("Log window")
                                    .font(Theme.font.headline)
                                    .foregroundStyle(Theme.color.text.primary)
                                ScrollView(.horizontal) {
                                    Text(logText)
                                        .font(Theme.font.monoCaption)
                                        .textSelection(.enabled)
                                        .padding(Theme.spacing.sm)
                                }
                                .background(Theme.color.bg.surfaceInset)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radius.sm))
                            }
                        } else {
                            Text("No log snapshot was captured with this report.")
                                .font(Theme.font.caption)
                                .foregroundStyle(Theme.color.text.subdued)
                        }

                        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                            Text("MetricKit payload")
                                .font(Theme.font.headline)
                                .foregroundStyle(Theme.color.text.primary)
                            ScrollView(.horizontal) {
                                Text(payloadText.isEmpty ? "(unavailable)" : payloadText)
                                    .font(Theme.font.monoCaption)
                                    .textSelection(.enabled)
                                    .padding(Theme.spacing.sm)
                            }
                            .background(Theme.color.bg.surfaceInset)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.sm))
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            logText = DiagnosticsCollector.shared.readLog(for: report) ?? ""
            payloadText = DiagnosticsCollector.shared.readPayloadJSON(for: report) ?? ""
        }
    }
}
