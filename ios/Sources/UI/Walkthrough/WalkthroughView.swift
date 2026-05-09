import SwiftUI

@MainActor
public struct WalkthroughView: View {
    @State private var coordinator = WalkthroughCoordinator.shared
    /// Core-Haptics-backed tap feedback. Used for Begin (fires
    /// reliably — no recording active yet). The Weiter tap does not
    /// produce a haptic on iPhone 17 Pro / iOS 26 because iOS silences
    /// every haptic path (UIImpactFeedbackGenerator, `.sensoryFeedback`,
    /// `CHHapticEngine` with `playsHapticsOnly = true`, even
    /// `AudioServicesPlaySystemSound`) while an `AVAudioEngine` is
    /// recording in `.playAndRecord`. Voice Memos avoids this by
    /// using `.record` only — we can't, since we need playback for
    /// TTS in the same session. `DSButtonStyle` already flashes the
    /// button visually on press; that's the user-visible feedback
    /// during a segment. `haptics.tap()` is left in the action so it
    /// fires in any non-recording state (e.g., end-of-walkthrough).
    @StateObject private var haptics = HapticPlayer()
    // The enrichment sheet was previously presented by a "Frage stellen"
    // ghost button in the bottom action stack. That button was dropped
    // along with Skip / Finish-early so the dialog flows uninterrupted;
    // the sheet itself is intentionally not deleted (see EnrichmentSheet
    // below) in case a voice-driven trigger surfaces it again later.
    @State private var modelState: ParakeetManager.LoadState = .idle

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(
                    title: headerTitle,
                    total: headerTotal,
                    current: headerCurrent,
                    onClose: headerCloseAction
                )

                // The model-load banner used to live here; the floating
                // bottom CTA carries that signal now (label + spinner +
                // disabled state) so we don't double up.

                // No in-app state pill: it crowded the layout. The
                // canonical state indicator lives in the Dynamic Island
                // via the Live Activity, which iOS surfaces the moment
                // the user backgrounds the app. While the app is on
                // screen, the EDITOR card + timer + bottom buttons
                // already convey what's happening.

                ScrollView {
                    VStack(spacing: Theme.spacing.lg) {
                        // The EDITOR transcript card was removed: the TTS
                        // engine already speaks the line, so showing it
                        // visually was redundant noise. The user hears
                        // the question; the screen carries event context
                        // + the timer.

                        if let current = currentEvent {
                            EventCard(event: current,
                                      index: currentIndex,
                                      total: coordinator.events.count)
                        }

                        // ListeningTimer is rendered in the bottom
                        // overlay (just above the BottomActionStack) so
                        // its distance from the bottom of the screen
                        // stays constant — content above can grow/shrink
                        // without shifting the counter.

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
                    .padding(.bottom, scrollBottomInset)
                }
            }

            // State indicator lives in the Dynamic Island via the live
            // activity (see WalkthroughCoordinator.startLiveActivityIfNeeded).
            // Per Apple HIG we keep the in-app surface free of redundant
            // status chrome.

            VStack(spacing: 0) {
                Spacer()
                if coordinator.state.isInEventLoop {
                    // Combined status row above the timer. Same horizontal
                    // slot covers the AI-speaking indicator AND the silence
                    // hint; only one is ever visible. Reserved-height so the
                    // ListeningTimer's vertical position never jumps.
                    StatusIndicator(
                        isSpeaking: coordinator.isSpeaking,
                        silenceLevel: coordinator.silenceLevel,
                        isWakeListening: coordinator.isWakeListening
                    )
                    .padding(.bottom, Theme.spacing.xs)

                    // Pinned counter — same Y from the bottom regardless
                    // of what's in the scroll area above. Lives in the
                    // overlay (not the scroll view) so EventCard growth
                    // can't push it around.
                    ListeningTimer(seconds: coordinator.elapsedSeconds)
                        .padding(.bottom, Theme.spacing.sm)
                }
                if coordinator.state.isInEventLoop {
                    // Single-action bottom: the dialog drives itself, so the
                    // user only ever needs to confirm "I'm done with this
                    // event" via Weiter. Skip / Finish-early / Frage-stellen
                    // were dropped because they encouraged interrupting the
                    // assistant rather than letting the dialogue flow. The
                    // wake-word "Hey Voice Diary" still triggers enrichment;
                    // a future skip-by-voice command can replace the button.
                    BottomActionStack {
                        Text(bottomHintText)
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        Button {
                            // No-op when iOS is muting haptics during
                            // recording — see comment on `haptics`.
                            // The button still feels live thanks to the
                            // `.dsPrimary` opacity / scale press
                            // animation baked into DSButtonStyle.
                            haptics.tap()
                            Task { await coordinator.advance() }
                        } label: {
                            Label("Weiter", systemImage: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
                    }
                } else if case .idle = coordinator.state {
                    BottomActionStack {
                        Button {
                            haptics.tap()
                            Task { await coordinator.begin() }
                        } label: {
                            startCtaLabel
                        }
                        .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
                        .disabled(!isModelReady || coordinator.isPreviewing)
                    }
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .task {
            // Surface Parakeet load state so the user sees the
            // ~1.2 GB first-launch download instead of silently
            // hitting "Sitzung starten" before the model is ready.
            await ParakeetManager.shared.warmUp()
            modelState = await ParakeetManager.shared.loadState
        }
        .onAppear {
            // Boot Core Haptics ahead of the first tap so the initial
            // Begin / Weiter is as crisp as subsequent ones. The
            // engine survives audio-recording mute via
            // `playsHapticsOnly = true`.
            haptics.start()
        }
    }

    /// Bottom inset for the scroll view. Reserves space for the floating
    /// CTA / action stack so long lists can scroll behind it without
    /// the last item getting trapped underneath.
    private var scrollBottomInset: CGFloat {
        switch coordinator.state {
        case .idle:
            return 120
        case .briefing, .eventOpener, .eventListening,
             .generalOpener, .generalListening,
             .driveByOpener, .driveByListening,
             .confirmingTodos:
            // Action stack (~190) + pinned timer (80 slot + 12 padding) +
            // breathing room — keeps the section card above both.
            return 320
        default:
            return Theme.spacing.lg
        }
    }

    /// Caption above the Weiter button. Phrased per state so the affordance
    /// reads correctly: in a normal listening loop "Weiter = next event",
    /// in todo confirmation "Weiter = skip this candidate".
    private var bottomHintText: String {
        if case .confirmingTodos = coordinator.state {
            return "Sag Ja, Nein oder formuliere die Aufgabe um. Weiter überspringt diese Aufgabe."
        }
        return "Sprich frei. Tippe Weiter, wenn du zum nächsten Termin willst."
    }

    private var isModelReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// Label inside the floating "Sitzung starten" button. While the
    /// Parakeet model is still downloading the label switches to the
    /// load state + a spinner — the user can read why the CTA is
    /// disabled without an extra banner.
    @ViewBuilder
    private var startCtaLabel: some View {
        switch modelState {
        case .ready:
            let count = coordinator.previewEvents.count
            switch count {
            case 0: Label("Sitzung starten", systemImage: "play.fill")
            case 1: Label("Sitzung starten (1 Termin)", systemImage: "play.fill")
            default: Label("Sitzung starten (\(count) Termine)", systemImage: "play.fill")
            }
        case .idle:
            HStack(spacing: Theme.spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.color.text.inverse)
                Text("Sprachmodell wird vorbereitet…")
            }
        case .loading:
            HStack(spacing: Theme.spacing.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.color.text.inverse)
                Text("Lade Sprachmodell — ~1,2 GB")
            }
        case .failed(let msg):
            Label("Sprachmodell-Fehler: \(msg.prefix(40))", systemImage: "exclamationmark.triangle.fill")
        }
    }

    // MARK: - flow header config

    /// During the per-event walkthrough we promote the event subject as the
    /// page title — this matches the design's "the title IS the H1" rule
    /// and lets the progress segments carry the step counter.
    private var headerTitle: String {
        switch coordinator.state {
        case .idle:                            return "Abend"
        case .confirmingTodos:                 return "Eine Sache noch"
        case .ingesting:                       return "Lade hoch"
        case .done:                            return "Sitzung abgeschlossen"
        case .failed:                          return "Fehler"
        case .briefing where currentEvent != nil,
             .eventOpener, .eventListening:    return currentEvent?.subject ?? "Termin"
        case .generalOpener, .generalListening,
             .driveByOpener, .driveByListening:
            return coordinator.currentSectionTitle ?? "Abend"
        default:                               return "Abend"
        }
    }

    private var headerTotal: Int {
        switch coordinator.state {
        case .eventOpener, .eventListening:
            return coordinator.calendarProgress?.total ?? coordinator.events.count
        case .confirmingTodos:
            return coordinator.todoCandidateProgress?.total ?? 0
        default:
            return 0
        }
    }

    private var headerCurrent: Int {
        switch coordinator.state {
        case .eventOpener, .eventListening:
            return coordinator.calendarProgress?.current ?? 0
        case .confirmingTodos:
            return (coordinator.todoCandidateProgress?.index ?? 0) + 1
        default:
            return 0
        }
    }

    private var headerCloseAction: (() -> Void)? {
        switch coordinator.state {
        case .idle, .done, .failed: return nil
        default: return { Task { await coordinator.cancel() } }
        }
    }

    // MARK: - derived

    /// Index of the calendar event currently being walked, or -1.
    /// Used by the EventCard render below.
    private var currentIndex: Int {
        if let progress = coordinator.calendarProgress {
            return progress.current - 1
        }
        if case .briefing = coordinator.state, !coordinator.events.isEmpty {
            return 0
        }
        return -1
    }

    private var currentEvent: ServerCalendarEvent? {
        coordinator.currentCalendarEvent
    }
}

// MARK: - subviews

private struct EventCard: View {
    let event: ServerCalendarEvent
    let index: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            // Row 1 — time range (mono, tabular). Has its own line so
            // the wrap-fest from the old single-row layout is gone.
            Text(timeRange(event))
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.subdued)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            // Row 2 — attendee count + RSVP chip on the same line.
            // Both items use icons + short labels and never overflow,
            // so they fit comfortably on one row.
            HStack(spacing: Theme.spacing.sm) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 12))
                    Text("\(event.attendeeCount) \(event.attendeeCount == 1 ? "Teilnehmer" : "Teilnehmende")")
                        .font(Theme.font.caption)
                }
                .foregroundStyle(Theme.color.text.secondary)

                Spacer(minLength: Theme.spacing.xs)

                HStack(spacing: 4) {
                    Circle()
                        .fill(rsvpColor)
                        .frame(width: 7, height: 7)
                    Text(rsvpLabel)
                        .font(Theme.font.caption)
                }
                .foregroundStyle(Theme.color.text.secondary)
                .lineLimit(1)
            }

            // Row 3 (optional) — attendee names as a single wrapped
            // line. Capped at two lines and clipped with ellipsis so
            // big DLs (12+ people) don't blow up the card.
            if !event.attendees.isEmpty {
                Text(event.attendees.prefix(4).map(\.name).joined(separator: ", "))
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .lineLimit(2)
                    .truncationMode(.tail)
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

    private var rsvpColor: Color {
        switch event.rsvp_status {
        case "organizer": return Theme.color.text.link
        case "accepted":  return Theme.color.status.success
        case "tentative": return Theme.color.status.warning
        default:          return Theme.color.text.subdued
        }
    }

    private var rsvpLabel: String {
        switch event.rsvp_status {
        case "organizer": return "Organisator"
        case "accepted":  return "zugesagt"
        case "tentative": return "vorläufig"
        default:          return "ohne Antwort"
        }
    }

    private func timeRange(_ ev: ServerCalendarEvent) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        guard let start = ev.startDate, let end = ev.endDate else { return "" }
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

/// Walkthrough listening counter. Matches the drive-by Aufnahme counter
/// (`CaptureView.recordingBody`) on font size, weight, and slot height so
/// both screens read as the same component at the same vertical position.
private struct ListeningTimer: View {
    let seconds: Int
    var body: some View {
        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 64, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.color.text.primary)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: 80)             // matches CaptureView's recording slot
    }
}

/// Combined status row above the ListeningTimer. Surfaces, in priority
/// order:
///   1. "Stimme spricht …" while the assistant is talking (covers both
///      Piper synthesis and audible playback).
///   2. "Höre auf 'Weiter' …" while the M7 wake-word window is open.
///   3. "Stille seit Xs" once a lull threshold has been crossed.
///   4. Empty (reserved-height slot) the rest of the time.
///
/// Only one signal is shown at a time so the row stays calm. The fixed
/// frame height prevents the surrounding overlay from shifting when the
/// status changes mid-event.
@MainActor
private struct StatusIndicator: View {
    let isSpeaking: Bool
    let silenceLevel: Int
    let isWakeListening: Bool

    var body: some View {
        HStack(spacing: Theme.spacing.xs) {
            if isSpeaking {
                ProgressView().controlSize(.small)
                Text("Stimme spricht …")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            } else if isWakeListening {
                // Wake-word window is open — the ping has played and
                // the streaming ASR is hot. Take priority over the
                // silence indicator so the user knows we're listening
                // for a command, not just counting quiet seconds.
                Image(systemName: "waveform.badge.mic")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.link)
                Text("Höre auf „Weiter\" …")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.link)
            } else if silenceLevel >= 6 {
                // 3 s threshold isn't surfaced here — that slot belongs
                // to the wake-word indicator above. We start showing
                // the silence counter at 6 s so the user sees a clean
                // sequence: (nothing) → "Höre auf 'Weiter'" →
                // "Stille seit 6s" → "Stimme spricht …" → 15 s update
                // → 20 s auto-advance.
                Image(systemName: "ear.badge.waveform")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                Text("Stille seit \(silenceLevel)s")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)                  // reserved slot — prevents layout jumps
        .opacity(isSpeaking || isWakeListening || silenceLevel >= 6 ? 1 : 0)
        .animation(Theme.motion.snappy, value: isSpeaking)
        .animation(Theme.motion.snappy, value: isWakeListening)
        .animation(Theme.motion.snappy, value: silenceLevel)
    }
}

@MainActor
private struct StartCard: View {
    let coordinator: WalkthroughCoordinator
    @State private var selectedDate: Date = Date()
    @State private var showPicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.md) {
            Text("Bereit für die Abend-Reflexion?")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text("Wir gehen die zugesagten Termine des Tages chronologisch durch.")
                .font(Theme.font.callout)
                .foregroundStyle(Theme.color.text.secondary)

            dateNavigator
            recordedBadge

            DayOverview(
                events: coordinator.previewEvents,
                isLoading: coordinator.isPreviewing,
                error: coordinator.previewError,
                onRefresh: {
                    Task {
                        await coordinator.previewDay(selectedDate)
                        await coordinator.loadRecordedDates(around: selectedDate)
                    }
                },
                onOpenSettings: {
                    AppRouter.shared.selectedTab = .mehr
                }
            )
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
            await coordinator.loadRecordedDates(around: selectedDate)
        }
    }

    /// Three-part date navigator: ←  date  →
    /// Mirrors the Apple Calendar / Health pattern. The centred label
    /// is tappable and opens the system date picker for free-form jumps.
    /// The right chevron auto-disables on today (consistent with the
    /// existing `in: ...Date()` upper bound).
    private var dateNavigator: some View {
        HStack(spacing: Theme.spacing.xs) {
            chevronButton(systemName: "chevron.left", direction: -1, enabled: true)

            Button { showPicker.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                    Text(Self.dateLabel(selectedDate))
                        .font(Theme.font.callout.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.color.text.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.bg.containerInset)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tag wählen")
            .sheet(isPresented: $showPicker) {
                RecordingDatePickerSheet(
                    selectedDate: $selectedDate,
                    recordedDates: coordinator.recordedDates,
                    isPresented: $showPicker
                )
                .presentationDetents([.height(520)])
                .presentationDragIndicator(.visible)
                // Layer order: thick material first (the glass blur), then
                // a translucent surface tint on top to dial down the
                // bleed-through from the StartCard behind. Result reads as
                // Liquid Glass but the calendar grid stays legible.
                .presentationBackground {
                    ZStack {
                        Rectangle().fill(.thickMaterial)
                        Rectangle().fill(Theme.color.bg.surface.opacity(0.55))
                    }
                    .ignoresSafeArea()
                }
            }

            chevronButton(systemName: "chevron.right",
                          direction: 1,
                          enabled: !Calendar.current.isDateInToday(selectedDate))
        }
        .onChange(of: selectedDate) { _, newValue in
            coordinator.setSelectedDate(newValue)
            Task { await coordinator.previewDay(newValue) }
        }
    }

    /// Marker shown next to the day overview header when the selected
    /// date already has at least one recording on the server.
    @ViewBuilder
    fileprivate var recordedBadge: some View {
        if coordinator.recordedDates.contains(Self.isoDay(selectedDate)) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color.status.success)
                    .frame(width: 8, height: 8)
                Text("Aufnahme bereits vorhanden")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
            .padding(.horizontal, Theme.spacing.xs)
        }
    }

    fileprivate static let isoDay: (Date) -> String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return { f.string(from: $0) }
    }()

    /// One step ± a calendar day. Disabled state is stroked instead of
    /// filled to communicate "no further" without colour-only signal.
    private func chevronButton(systemName: String, direction: Int, enabled: Bool) -> some View {
        Button {
            guard enabled,
                  let next = Calendar.current.date(byAdding: .day, value: direction, to: selectedDate)
            else { return }
            // Clamp at today for the forward step (matches `in: ...Date()`).
            selectedDate = (direction > 0 && next > Date()) ? Date() : next
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(enabled ? Theme.color.text.primary : Theme.color.text.subdued)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.bg.containerInset)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(direction < 0 ? "Vorheriger Tag" : "Nächster Tag")
    }

    private static let dateLabel: (Date) -> String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.doesRelativeDateFormatting = true   // "Heute" / "Gestern" when applicable
        f.dateStyle = .medium                  // e.g. "30. Apr. 2026"
        f.timeStyle = .none
        return { f.string(from: $0) }
    }()

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
    let error: ConnectionDiagnosis?
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

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
                ConnectionErrorCard(
                    diagnosis: error,
                    isLoading: isLoading,
                    onRefresh: onRefresh,
                    onOpenSettings: onOpenSettings
                )
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

/// Replaces the single-line red error string in DayOverview with a
/// proper card: icon + title + actionable hint + technical detail in a
/// monospaced caption + a primary action ("Tagesübersicht erneut laden"
/// or "Einstellungen öffnen", depending on the diagnosis).
@MainActor
private struct ConnectionErrorCard: View {
    let diagnosis: ConnectionDiagnosis
    let isLoading: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

    @State private var detailExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            HStack(alignment: .top, spacing: Theme.spacing.sm) {
                Image(systemName: diagnosis.systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.color.status.destructive)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnosis.title)
                        .font(Theme.font.callout.weight(.semibold))
                        .foregroundStyle(Theme.color.text.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(diagnosis.hint)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let detail = diagnosis.detail, !detail.isEmpty {
                Button {
                    detailExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: detailExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(detailExpanded ? "Technische Details ausblenden" : "Technische Details")
                            .font(Theme.font.caption2)
                    }
                    .foregroundStyle(Theme.color.text.subdued)
                }
                .buttonStyle(.plain)

                if detailExpanded {
                    Text(detail)
                        .font(Theme.font.monoCaption)
                        .foregroundStyle(Theme.color.text.subdued)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous)
                                .fill(Theme.color.bg.surface)
                        )
                }
            }

            primaryAction
        }
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.containerInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.status.destructive.opacity(0.30), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch diagnosis.kind {
        case .notConfigured:
            Button {
                onOpenSettings()
            } label: {
                Label("Einstellungen öffnen", systemImage: "gearshape.fill")
            }
            .buttonStyle(.dsPrimary(fullWidth: true))
        default:
            Button {
                onRefresh()
            } label: {
                if isLoading {
                    HStack(spacing: Theme.spacing.xs) {
                        ProgressView().controlSize(.small)
                            .tint(Theme.color.text.inverse)
                        Text("Lade …")
                    }
                } else {
                    Label("Tagesübersicht erneut laden", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.dsPrimary(fullWidth: true))
            .disabled(isLoading)
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

/// CLOSING confirmation pass for an implicit-todo candidate. Renders the
/// candidate as a card visually consistent with `EventCard` so the user
/// reads the confirmation pass as another listening step instead of a
/// modal popover. Voice-driven: the answer is captured by the coordinator's
/// `runTodoAnswerCapture` (yes/no/refine via Parakeet → TodoAnswerParser).
/// The Weiter button in the parent's bottom action stack maps to "skip
/// this candidate" via `coordinator.advance()`.
@MainActor
private struct TodoConfirmationCard: View {
    let coordinator: WalkthroughCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            Text("AUFGABE")
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.subdued)
                .tracking(0.5)

            Text(coordinator.currentTodoCandidate?.text ?? "")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.color.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        VStack(spacing: Theme.spacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.color.status.success)

            VStack(spacing: 6) {
                Text(summaryText)
                    .font(Theme.font.body)
                    .foregroundStyle(Theme.color.text.secondary)
                    .multilineTextAlignment(.center)
                if let id = coordinator.sessionID {
                    Text(id)
                        .font(Theme.font.monoCaption)
                        .foregroundStyle(Theme.color.text.subdued)
                        .opacity(0.7)
                }
            }

            Button("Neue Sitzung") {
                Task { await coordinator.cancel() }
            }
            .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.spacing.xl)
        .padding(.vertical, Theme.spacing.xl)
    }

    private var summaryText: String {
        let events = coordinator.events.count
        let todos  = coordinator.confirmedImplicitCount
        switch (events, todos) {
        case (0, _):  return "Sitzung gespeichert."
        case (_, 0):  return "\(events) Termine durchgegangen."
        default:      return "\(events) Termine durchgegangen, \(todos) Aufgaben übernommen."
        }
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

/// Sheet-hosted month grid for picking a walkthrough date. Days that
/// already have a recording are underlined with a small dot below the
/// number; future days (after today) are disabled. Replaces the prior
/// SwiftUI graphical-DatePicker popover, which mis-rendered inside the
/// compact-popover adaptation on iOS 26 (only one weekday column).
@MainActor
private struct RecordingDatePickerSheet: View {
    @Binding var selectedDate: Date
    let recordedDates: Set<String>
    @Binding var isPresented: Bool

    @State private var visibleMonth: Date = Date()

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2 // Monday
        return c
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.spacing.md) {
                Text("Der gewählte Tag ist der Tag, für den der Tagebuch-Eintrag aufgenommen wird.")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                monthHeader
                weekdayHeader
                monthGrid
                legend
            }
            .padding(.horizontal, Theme.spacing.md)
            .padding(.top, Theme.spacing.xxs)
            .padding(.bottom, Theme.spacing.md)
            .navigationTitle("Tag wählen")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                visibleMonth = calendar.date(
                    from: calendar.dateComponents([.year, .month], from: selectedDate)
                ) ?? selectedDate
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Theme.color.text.primary)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.bg.containerInset)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
            Text(Self.monthLabel.string(from: visibleMonth).capitalized)
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
            Button { step(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(canStepForward ? Theme.color.text.primary : Theme.color.text.subdued)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                            .fill(Theme.color.bg.containerInset)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canStepForward)
        }
    }

    private var weekdayHeader: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let firstIdx = (calendar.firstWeekday - 1) % 7
        let ordered = (0..<7).map { symbols[(firstIdx + $0) % 7] }
        return HStack(spacing: 0) {
            ForEach(ordered, id: \.self) { sym in
                Text(sym)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        let cells = monthCells()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(cells.indices, id: \.self) { i in
                if let day = cells[i] {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday    = calendar.isDateInToday(day)
        let isFuture   = day > calendar.startOfDay(for: Date())
                         && !calendar.isDateInToday(day)
        let hasRecord  = recordedDates.contains(Self.isoDay.string(from: day))

        return Button {
            guard !isFuture else { return }
            selectedDate = day
            isPresented = false
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(Theme.font.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isFuture ? Theme.color.text.subdued
                        : (isSelected ? Theme.color.text.inverse : Theme.color.text.primary)
                    )
                Circle()
                    .fill(hasRecord ? Theme.color.status.success : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                    .fill(isSelected ? Theme.color.bg.inverse : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                    .strokeBorder(isToday && !isSelected ? Theme.color.border.subdued : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    private var legend: some View {
        HStack(spacing: Theme.spacing.sm) {
            HStack(spacing: 6) {
                Circle().fill(Theme.color.status.success).frame(width: 6, height: 6)
                Text("Aufnahme vorhanden")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
            Spacer()
        }
    }

    private func step(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        visibleMonth = next
    }

    private var canStepForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: visibleMonth) else { return false }
        let startOfNext = calendar.date(from: calendar.dateComponents([.year, .month], from: next)) ?? next
        return startOfNext <= Date()
    }

    /// Returns 7-aligned cells for the visible month: leading nils for
    /// days before the 1st, then each day, padded with trailing nils so
    /// the grid is rectangular.
    private func monthCells() -> [Date?] {
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)),
            let range = calendar.range(of: .day, in: .month, for: monthStart)
        else { return [] }
        let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: monthStart) {
                cells.append(d)
            }
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}
