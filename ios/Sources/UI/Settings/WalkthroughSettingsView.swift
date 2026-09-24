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
                FlowHeader(title: "Event filter")

                Form {
                    Section {
                        Toggle("Include all-day events", isOn: $includeAllDay)
                            .tint(Theme.color.text.link)
                            .onChange(of: includeAllDay) { _, new in
                                WalkthroughSettingsStore.setIncludeAllDay(new)
                                WalkthroughCoordinator.shared.reapplyPreviewFilter()
                            }

                        Toggle("Include tentative events", isOn: $includeTentative)
                            .tint(Theme.color.text.link)
                            .onChange(of: includeTentative) { _, new in
                                WalkthroughSettingsStore.setIncludeTentative(new)
                                WalkthroughCoordinator.shared.reapplyPreviewFilter()
                            }

                        Toggle("Include not-accepted events", isOn: $includeNotAccepted)
                            .tint(Theme.color.text.link)
                            .onChange(of: includeNotAccepted) { _, new in
                                WalkthroughSettingsStore.setIncludeNotAccepted(new)
                                WalkthroughCoordinator.shared.reapplyPreviewFilter()
                            }
                    } header: {
                        Text("Which events count?")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("By default, the evening only runs through accepted events with a start time.")
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
