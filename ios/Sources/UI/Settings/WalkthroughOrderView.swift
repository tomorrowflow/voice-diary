import SwiftUI

/// Drag-to-reorder view for the walkthrough section plan (SPEC §6).
/// Renders the ordered list of all three section kinds (generals + the
/// two system sections) with drag handles. Persists each move
/// immediately so the next walkthrough picks up the new order.
@MainActor
public struct WalkthroughOrderView: View {
    @State private var order: [WalkthroughSection] = WalkthroughSettingsStore.order
    @State private var generals: [GeneralSection] = WalkthroughSettingsStore.generals

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Order")

                List {
                    Section {
                        ForEach(order) { entry in
                            OrderRow(entry: entry, generals: generals)
                                .listRowBackground(Theme.color.bg.containerInset)
                        }
                        .onMove(perform: move)
                    } header: {
                        Text("Evening order")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("Press and hold an entry, then drag it into position. The walkthrough runs the list top to bottom.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                }
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            order = WalkthroughSettingsStore.order
            generals = WalkthroughSettingsStore.generals
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        WalkthroughSettingsStore.saveOrder(order)
    }
}

private struct OrderRow: View {
    let entry: WalkthroughSection
    let generals: [GeneralSection]

    var body: some View {
        HStack(spacing: Theme.spacing.sm) {
            Image(systemName: iconName)
                .foregroundStyle(Theme.color.text.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font.body.weight(.medium))
                    .foregroundStyle(Theme.color.text.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.spacing.xxs)
    }

    private var iconName: String {
        switch entry {
        case .general:        return "text.bubble"
        case .calendarEvents: return "calendar"
        case .voiceNote:        return "mic.fill"
        }
    }

    private var title: String {
        switch entry {
        case .general(let id):
            return generals.first { $0.id == id }?.title ?? String(localized: "(unknown)")
        case .calendarEvents:
            return String(localized: "Events")
        case .voiceNote:
            return String(localized: "Notes")
        }
    }

    private var subtitle: String? {
        switch entry {
        case .general(let id):
            return generals.first { $0.id == id }?.introText
        case .calendarEvents:
            return String(localized: "Per-event loop with openers + listen phase.")
        case .voiceNote:
            return String(localized: "Picks up open notes and asks for free reflection.")
        }
    }
}
