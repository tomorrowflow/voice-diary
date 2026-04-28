import SwiftUI

@MainActor
public struct WalkthroughView: View {
    @State private var coordinator = WalkthroughCoordinator.shared

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

private struct StartCard: View {
    let coordinator: WalkthroughCoordinator

    var body: some View {
        VStack(spacing: Theme.spacing.md) {
            Text("Bereit für die Abend-Reflexion?")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text("Wir gehen die Termine des Tages chronologisch durch. Du sprichst, wir hören zu.")
                .font(Theme.font.callout)
                .foregroundStyle(Theme.color.text.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await coordinator.begin() }
            } label: {
                Label("Sitzung starten", systemImage: "play.fill")
            }
            .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
        }
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
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
