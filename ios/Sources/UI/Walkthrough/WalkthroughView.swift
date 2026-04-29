import SwiftUI

@MainActor
public struct WalkthroughView: View {
    @State private var coordinator = WalkthroughCoordinator.shared
    @State private var showEnrichment: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.color.bg.surface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Theme.spacing.lg) {
                        StateHeader(coordinator: coordinator)

                        if coordinator.state.isSpeaking || coordinator.state.isListening {
                            SpokenLineCard(text: coordinator.lastSpoken)
                        }

                        if let current = currentEvent {
                            EventCard(event: current,
                                      index: currentIndex,
                                      total: coordinator.events.count)
                        }

                        if coordinator.state.isListening {
                            ListeningTimer(seconds: coordinator.elapsedSeconds)
                            if !coordinator.statusHint.isEmpty {
                                Text(coordinator.statusHint)
                                    .font(Theme.font.callout)
                                    .foregroundStyle(Theme.color.status.warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.spacing.sm)
                            }
                            ListeningControls(coordinator: coordinator)
                            EnrichmentTrigger(
                                isEnriching: coordinator.isEnriching,
                                action: { showEnrichment = true }
                            )
                        }

                        switch coordinator.state {
                        case .idle:                StartCard(coordinator: coordinator)
                        case .ingesting:           UploadingCard()
                        case .done:                DoneCard(coordinator: coordinator)
                        case .failed(let msg):     ErrorCard(message: msg, coordinator: coordinator)
                        default:                   EmptyView()
                        }
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.lg)
                }
            }
            .navigationTitle("Abend")
            .sheet(isPresented: $showEnrichment) {
                EnrichmentSheet(coordinator: coordinator, isPresented: $showEnrichment)
            }
        }
    }

    // MARK: - derived

    private var currentIndex: Int {
        switch coordinator.state {
        case .eventOpener(let i), .eventListening(let i): return i
        default: return -1
        }
    }

    private var currentEvent: ServerCalendarEvent? {
        guard currentIndex >= 0,
              currentIndex < coordinator.events.count else { return nil }
        return coordinator.events[currentIndex]
    }
}

// MARK: - subviews

private struct StateHeader: View {
    let coordinator: WalkthroughCoordinator
    var body: some View {
        HStack(spacing: Theme.spacing.sm) {
            Circle()
                .fill(coordinator.state.isListening
                      ? Theme.color.status.destructive
                      : (coordinator.state.isSpeaking ? Theme.color.status.warning : Theme.color.text.subdued))
                .frame(width: 10, height: 10)
            Text(coordinator.state.label)
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
        }
    }
}

private struct SpokenLineCard: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font.callout)
            .foregroundStyle(Theme.color.text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                    .fill(Theme.color.bg.containerInset)
            )
    }
}

private struct EventCard: View {
    let event: ServerCalendarEvent
    let index: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text("Termin \(index + 1) / \(total)")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
            Text(event.subject)
                .font(Theme.font.title3)
                .foregroundStyle(Theme.color.text.primary)
            HStack(spacing: Theme.spacing.xs) {
                Image(systemName: "clock")
                Text(timeRange(event))
            }
            .font(Theme.font.subheadline)
            .foregroundStyle(Theme.color.text.secondary)
            if !event.attendees.isEmpty {
                HStack(spacing: Theme.spacing.xs) {
                    Image(systemName: "person.2")
                    Text(event.attendees.prefix(3).map(\.name).joined(separator: ", "))
                        .lineLimit(1)
                }
                .font(Theme.font.subheadline)
                .foregroundStyle(Theme.color.text.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private func timeRange(_ ev: ServerCalendarEvent) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        guard let start = ev.startDate, let end = ev.endDate else { return "" }
        return "\(f.string(from: start))–\(f.string(from: end))"
    }
}

private struct ListeningTimer: View {
    let seconds: Int
    var body: some View {
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 36, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.color.text.secondary)
            .frame(maxWidth: .infinity)
    }
}

private struct ListeningControls: View {
    let coordinator: WalkthroughCoordinator

    var body: some View {
        VStack(spacing: Theme.spacing.sm) {
            Button {
                Task { await coordinator.advance() }
            } label: {
                Label("Weiter", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))

            HStack(spacing: Theme.spacing.sm) {
                Button {
                    Task { await coordinator.skip() }
                } label: {
                    Text("Überspringen")
                }
                .buttonStyle(.dsSecondary(fullWidth: true))

                Button {
                    Task { await coordinator.finishEarly() }
                } label: {
                    Text("Ich bin fertig")
                }
                .buttonStyle(.dsGhost(fullWidth: true))
            }
        }
    }
}

@MainActor
private struct StartCard: View {
    let coordinator: WalkthroughCoordinator
    @State private var selectedDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.md) {
            Text("Bereit für die Abend-Reflexion?")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text("Wir gehen die zugesagten Termine des Tages chronologisch durch. Tentative oder nicht zugesagte Termine werden übersprungen.")
                .font(Theme.font.callout)
                .foregroundStyle(Theme.color.text.secondary)

            DatePicker(
                "Tag",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .onChange(of: selectedDate) { _, newValue in
                coordinator.setSelectedDate(newValue)
                Task { await coordinator.previewDay(newValue) }
            }
            .padding(.horizontal, Theme.spacing.sm)
            .padding(.vertical, Theme.spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                    .fill(Theme.color.bg.containerInset)
            )

            DayOverview(
                events: coordinator.previewEvents,
                isLoading: coordinator.isPreviewing,
                error: coordinator.previewError
            )

            Button {
                Task { await coordinator.begin() }
            } label: {
                Label(startLabel, systemImage: "play.fill")
            }
            .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
            .disabled(coordinator.isPreviewing)
        }
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .task {
            // Initial load when the view first appears.
            selectedDate = coordinator.selectedDate
            await coordinator.previewDay()
        }
    }

    private var startLabel: String {
        let count = coordinator.previewEvents.count
        switch count {
        case 0: return "Sitzung starten"
        case 1: return "Sitzung starten (1 Termin)"
        default: return "Sitzung starten (\(count) Termine)"
        }
    }
}

/// Vertical-rail day timeline: 6 AM → 10 PM with each event placed on
/// its real time slot. SPEC §6.1 mentions chronological walk; this card
/// makes the order visible before the user commits.
@MainActor
private struct DayOverview: View {
    let events: [ServerCalendarEvent]
    let isLoading: Bool
    let error: String?

    private static let dayStartHour: Double = 6
    private static let dayEndHour: Double = 22
    private static let pixelsPerHour: Double = 28

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            HStack {
                Text("Tagesübersicht")
                    .font(Theme.font.subheadline)
                    .foregroundStyle(Theme.color.text.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }

            if let error {
                Text(error)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.status.destructive)
            } else if events.isEmpty && !isLoading {
                Text("Keine zugesagten Termine.")
                    .font(Theme.font.callout)
                    .foregroundStyle(Theme.color.text.subdued)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.spacing.sm)
            } else {
                timelineRail
            }
        }
    }

    private var timelineRail: some View {
        ZStack(alignment: .topLeading) {
            // Hour ticks
            VStack(spacing: 0) {
                ForEach(Array(stride(from: Int(Self.dayStartHour), through: Int(Self.dayEndHour), by: 2)), id: \.self) { hour in
                    HStack(spacing: Theme.spacing.xs) {
                        Text(String(format: "%02d:00", hour))
                            .font(Theme.font.caption2.monospacedDigit())
                            .foregroundStyle(Theme.color.text.subdued)
                            .frame(width: 40, alignment: .leading)
                        Rectangle()
                            .fill(Theme.color.border.subdued)
                            .frame(height: 1)
                    }
                    .frame(height: Self.pixelsPerHour * 2)
                }
            }

            // Event blocks
            ForEach(Array(events.enumerated()), id: \.element.graph_event_id) { _, event in
                if let block = blockFor(event: event) {
                    EventBlock(event: event)
                        .padding(.leading, 48)
                        .frame(height: block.height)
                        .offset(y: block.offset)
                }
            }
        }
        .frame(height: (Self.dayEndHour - Self.dayStartHour) * Self.pixelsPerHour)
    }

    private func blockFor(event: ServerCalendarEvent) -> (offset: Double, height: Double)? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let cal = Calendar.current
        let startHour = Double(cal.component(.hour, from: start)) +
                        Double(cal.component(.minute, from: start)) / 60.0
        let endHour = Double(cal.component(.hour, from: end)) +
                      Double(cal.component(.minute, from: end)) / 60.0
        let clampedStart = max(Self.dayStartHour, min(Self.dayEndHour, startHour))
        let clampedEnd = max(clampedStart + 0.25, min(Self.dayEndHour, endHour))
        let offset = (clampedStart - Self.dayStartHour) * Self.pixelsPerHour
        let height = max(20, (clampedEnd - clampedStart) * Self.pixelsPerHour)
        return (offset, height)
    }
}

private struct EventBlock: View {
    let event: ServerCalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.xs) {
            Rectangle()
                .fill(blockColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.subject.isEmpty ? "(ohne Titel)" : event.subject)
                    .font(Theme.font.caption.weight(.medium))
                    .foregroundStyle(Theme.color.text.primary)
                    .lineLimit(1)
                Text(timeRange)
                    .font(Theme.font.caption2.monospacedDigit())
                    .foregroundStyle(Theme.color.text.secondary)
            }
            Spacer(minLength: 0)
            if event.attendeeCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                    Text("\(event.attendeeCount)")
                        .font(Theme.font.caption2)
                }
                .foregroundStyle(Theme.color.text.subdued)
            }
        }
        .padding(.horizontal, Theme.spacing.xs)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .fill(blockColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(blockColor.opacity(0.30), lineWidth: 1)
        )
    }

    private var blockColor: Color {
        switch event.rsvp_status {
        case "organizer": return Theme.color.text.link
        case "accepted":  return Theme.color.status.success
        case "tentative": return Theme.color.status.warning
        default:          return Theme.color.text.subdued
        }
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        guard let s = event.startDate, let e = event.endDate else { return "" }
        return "\(f.string(from: s))–\(f.string(from: e))"
    }
}

private struct UploadingCard: View {
    var body: some View {
        HStack(spacing: Theme.spacing.sm) {
            ProgressView()
            Text("Lade Sitzung hoch …")
                .font(Theme.font.callout)
                .foregroundStyle(Theme.color.text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.containerInset)
        )
    }
}

private struct DoneCard: View {
    let coordinator: WalkthroughCoordinator

    var body: some View {
        VStack(spacing: Theme.spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.color.status.success)
            Text("Sitzung abgeschlossen")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            if let id = coordinator.sessionID {
                Text(id)
                    .font(Theme.font.monoCaption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
            Button("Neue Sitzung") {
                Task { await coordinator.cancel() }
            }
            .buttonStyle(.dsSecondary(fullWidth: true))
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
    }
}

private struct ErrorCard: View {
    let message: String
    let coordinator: WalkthroughCoordinator

    var body: some View {
        VStack(spacing: Theme.spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.color.status.destructive)
            Text(message)
                .font(Theme.font.callout)
                .foregroundStyle(Theme.color.text.primary)
                .multilineTextAlignment(.center)
            Button("Erneut versuchen") {
                Task { await coordinator.cancel() }
            }
            .buttonStyle(.dsSecondary(fullWidth: true))
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
    }
}

// MARK: - Enrichment

private struct EnrichmentTrigger: View {
    let isEnriching: Bool
    let action: () -> Void

    var body: some View {
        if isEnriching {
            HStack(spacing: Theme.spacing.sm) {
                ProgressView()
                Text("Frage wird beantwortet …")
                    .font(Theme.font.callout)
                    .foregroundStyle(Theme.color.text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.spacing.sm)
        } else {
            Button(action: action) {
                Label("Frage stellen", systemImage: "magnifyingglass")
            }
            .buttonStyle(.dsGhost(fullWidth: true))
        }
    }
}

@MainActor
private struct EnrichmentSheet: View {
    let coordinator: WalkthroughCoordinator
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.color.bg.surface.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Theme.spacing.md) {
                    Text("Was möchtest du wissen?")
                        .font(Theme.font.headline)
                        .foregroundStyle(Theme.color.text.primary)
                    Text("Beispiele: „Was hat Christian gestern geschrieben?“ · „Was haben wir letzte Woche zur Migration gemacht?“")
                        .font(Theme.font.callout)
                        .foregroundStyle(Theme.color.text.secondary)
                    TextField(
                        "Frage eingeben",
                        text: $query,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(Theme.spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.bg.container)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
                    )
                    .focused($fieldFocused)
                    Spacer()
                    Button {
                        let q = query
                        query = ""
                        isPresented = false
                        Task { await coordinator.askEnrichment(query: q) }
                    } label: {
                        Label("Senden", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(Theme.spacing.md)
            }
            .navigationTitle("Frage stellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { isPresented = false }
                }
            }
            .onAppear { fieldFocused = true }
        }
    }
}
