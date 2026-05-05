import SwiftUI

/// Settings surface for the Abend walkthrough scope. Three toggles
/// (default off) controlling which calendar events get added to the
/// per-event loop. Lives behind the "Mehr" tab.
@MainActor
public struct WalkthroughSettingsView: View {
    @State private var includeAllDay: Bool = WalkthroughSettingsStore.current.includeAllDay
    @State private var includeTentative: Bool = WalkthroughSettingsStore.current.includeTentative
    @State private var includeNotAccepted: Bool = WalkthroughSettingsStore.current.includeNotAccepted

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Termin-Filter")

                Form {
                    Section {
                        Toggle("Ganztägige Termine einbeziehen", isOn: $includeAllDay)
                            .tint(Theme.color.text.link)
                            .onChange(of: includeAllDay) { _, new in
                                WalkthroughSettingsStore.setIncludeAllDay(new)
                                WalkthroughCoordinator.shared.reapplyPreviewFilter()
                            }

                        Toggle("Vorläufig zugesagte Termine einbeziehen", isOn: $includeTentative)
                            .tint(Theme.color.text.link)
                            .onChange(of: includeTentative) { _, new in
                                WalkthroughSettingsStore.setIncludeTentative(new)
                                WalkthroughCoordinator.shared.reapplyPreviewFilter()
                            }

                        Toggle("Nicht zugesagte Termine einbeziehen", isOn: $includeNotAccepted)
                            .tint(Theme.color.text.link)
                            .onChange(of: includeNotAccepted) { _, new in
                                WalkthroughSettingsStore.setIncludeNotAccepted(new)
                                WalkthroughCoordinator.shared.reapplyPreviewFilter()
                            }
                    } header: {
                        Text("Welche Termine zählen?")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("Standardmäßig läuft der Abend nur durch zugesagte Termine mit Uhrzeit.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
    }
}
