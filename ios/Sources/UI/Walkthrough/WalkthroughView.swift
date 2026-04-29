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
                        case .confirmingTodos:     TodoConfirmationCard(coordinator: coordinator)
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

/// Day overview rendered as a clean chronological list.
///
/// All-day events live in a dedicated "Ganztägig" header so they don't
/// distort the timed list. Timed events stack vertically — each row has
/// a fixed-width time column on the left, a colour bar keyed to RSVP
/// status, and an event card on the right. Overlapping events stay
/// side-by-side in reading order without absolute-positioning collisions.
@MainActor
private struct DayOverview: View {
    let events: [ServerCalendarEvent]
    let isLoading: Bool
    let error: String?

    private var timed: [ServerCalendarEvent] {
        events.filter { !$0.is_all_day && $0.startDate != nil }
              .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }
    private var allDay: [ServerCalendarEvent] {
        events.filter { $0.is_all_day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(spacing: Theme.spacing.xs) {
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
                if !allDay.isEmpty {
                    AllDaySection(events: allDay)
                }
                if !timed.isEmpty {
                    VStack(spacing: Theme.spacing.xs) {
                        ForEach(timed, id: \.graph_event_id) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
        }
    }
}

private struct AllDaySection: View {
    let events: [ServerCalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xxs) {
            Text("Ganztägig")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .padding(.horizontal, Theme.spacing.xs)
            ForEach(events, id: \.graph_event_id) { event in
                HStack(spacing: Theme.spacing.xs) {
                    Image(systemName: "sun.horizon.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                    Text(event.subject.isEmpty ? "(ohne Titel)" : event.subject)
                        .font(Theme.font.callout)
                        .foregroundStyle(Theme.color.text.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.spacing.sm)
                .padding(.vertical, Theme.spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.bg.containerInset)
                )
            }
        }
    }
}

/// One row in the chronological list. Time on the left, colour bar in
/// the middle keyed to RSVP, event details on the right.
private struct EventRow: View {
    let event: ServerCalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.sm) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeStart)
                    .font(Theme.font.caption.monospacedDigit())
                    .foregroundStyle(Theme.color.text.primary)
                Text(durationLabel)
                    .font(Theme.font.caption2.monospacedDigit())
                    .foregroundStyle(Theme.color.text.subdued)
            }
            .frame(width: 56, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.subject.isEmpty ? "(ohne Titel)" : event.subject)
                    .font(Theme.font.callout.weight(.medium))
                    .foregroundStyle(Theme.color.text.primary)
                    .lineLimit(2)
                if event.attendeeCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                        Text("\(event.attendeeCount) Teilnehmende")
                            .font(Theme.font.caption2)
                    }
                    .foregroundStyle(Theme.color.text.subdued)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.spacing.sm)
        .padding(.vertical, Theme.spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .fill(barColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                .strokeBorder(barColor.opacity(0.20), lineWidth: 1)
        )
    }

    private var barColor: Color {
        switch event.rsvp_status {
        case "organizer": return Theme.color.text.link
        case "accepted":  return Theme.color.status.success
        case "tentative": return Theme.color.status.warning
        default:          return Theme.color.text.subdued
        }
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var timeStart: String {
        guard let s = event.startDate else { return "—" }
        return Self.hhmm.string(from: s)
    }

    private var durationLabel: String {
        let m = event.durationMinutes
        if m <= 0 { return "" }
        if m < 60 { return "\(m) min" }
        if m % 60 == 0 { return "\(m / 60) h" }
        return String(format: "%d h %02d", m / 60, m % 60)
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

/// CLOSING confirmation pass for an implicit-todo candidate.
/// "Ja" / "Nein" / "Anders" — the latter reveals an inline text field
/// where the user can rephrase the action before confirming. Voice-driven
/// answers are phase B-2; this card is the button-driven fallback that
/// always works.
@MainActor
private struct TodoConfirmationCard: View {
    let coordinator: WalkthroughCoordinator
    @State private var refining: Bool = false
    @State private var refinedText: String = ""
    @FocusState private var refineFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.md) {
            if let progress = coordinator.todoCandidateProgress {
                Text("Aufgabe \(progress.index + 1) / \(progress.total)")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }

            Text(coordinator.currentTodoCandidate?.text ?? "")
                .font(Theme.font.title3)
                .foregroundStyle(Theme.color.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if refining {
                refineEditor
            } else {
                buttonRow
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
        .onChange(of: coordinator.todoCandidateProgress?.index) { _, _ in
            // Reset refine state every time we move to the next candidate.
            refining = false
            refinedText = ""
            refineFocused = false
        }
    }

    private var buttonRow: some View {
        VStack(spacing: Theme.spacing.sm) {
            Button {
                Task { await coordinator.confirmCurrentTodo() }
            } label: {
                Label("Ja, übernehmen", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))

            HStack(spacing: Theme.spacing.sm) {
                Button {
                    Task { await coordinator.rejectCurrentTodo() }
                } label: {
                    Text("Nein")
                }
                .buttonStyle(.dsSecondary(fullWidth: true))

                Button {
                    refinedText = coordinator.currentTodoCandidate?.text ?? ""
                    refining = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        refineFocused = true
                    }
                } label: {
                    Text("Anders")
                }
                .buttonStyle(.dsGhost(fullWidth: true))
            }
        }
    }

    private var refineEditor: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            TextField("Aufgabe umformulieren", text: $refinedText, axis: .vertical)
                .lineLimit(2...4)
                .focused($refineFocused)
                .padding(Theme.spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.bg.containerInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
                )

            HStack(spacing: Theme.spacing.sm) {
                Button {
                    refining = false
                    refinedText = ""
                    refineFocused = false
                } label: {
                    Text("Abbrechen")
                }
                .buttonStyle(.dsGhost(fullWidth: true))

                Button {
                    let snapshot = refinedText
                    refining = false
                    refineFocused = false
                    Task { await coordinator.refineCurrentTodo(snapshot) }
                } label: {
                    Text("Übernehmen")
                }
                .buttonStyle(.dsPrimary(fullWidth: true))
                .disabled(refinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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
