import SwiftUI

/// Editor for the user-defined "general" walkthrough sections (SPEC §6).
/// One row per general section showing title + intro preview, plus the two
/// non-editable system rows so the user can see the full section roster.
@MainActor
public struct WalkthroughSectionsView: View {
    @State private var generals: [GeneralSection] = WalkthroughSettingsStore.generals
    @State private var editorTarget: EditorTarget?

    /// One sheet binding for both add + edit. SwiftUI only honours the
    /// last `.sheet` modifier on a view, so we never declare two — we
    /// drive presentation through this one optional and let the editor
    /// branch on `.add` vs `.edit`.
    private enum EditorTarget: Identifiable {
        case add
        case edit(GeneralSection)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let s): return "edit:\(s.id)"
            }
        }

        var section: GeneralSection? {
            if case .edit(let s) = self { return s }
            return nil
        }
    }

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Abschnitte")

                List {
                    Section {
                        if generals.isEmpty {
                            Text("Noch keine eigenen Abschnitte. Tippe auf „Abschnitt hinzufügen“, um einen Opener mit Titel und Einleitung anzulegen.")
                                .font(Theme.font.callout)
                                .foregroundStyle(Theme.color.text.subdued)
                                .padding(.vertical, Theme.spacing.sm)
                        } else {
                            ForEach(generals) { section in
                                Button {
                                    editorTarget = .edit(section)
                                } label: {
                                    GeneralRow(section: section)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteGeneral)
                        }

                        Button {
                            editorTarget = .add
                        } label: {
                            Label("Abschnitt hinzufügen", systemImage: "plus")
                                .foregroundStyle(Theme.color.text.link)
                        }
                    } header: {
                        Text("Eigene Abschnitte")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("Jeder Abschnitt hat einen Titel und einen Einleitungssatz, den der Walkthrough als Opener vorliest.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }

                    Section {
                        SystemSectionRow(
                            iconName: "calendar",
                            title: "Termine",
                            subtitle: "Geht die zugesagten Termine des Tages chronologisch durch."
                        )
                        SystemSectionRow(
                            iconName: "mic.fill",
                            title: "Drive-by-Notizen",
                            subtitle: "Holt Notizen aus dem Tag ab und fragt nach offenem Restbedarf."
                        )
                    } header: {
                        Text("System-Abschnitte")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("Diese beiden Abschnitte sind fest verdrahtet, lassen sich aber unter „Reihenfolge“ frei verschieben.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $editorTarget) { target in
            GeneralEditorSheet(
                initial: target.section,
                onSave: { updated in
                    WalkthroughSettingsStore.upsertGeneral(updated)
                    generals = WalkthroughSettingsStore.generals
                },
                onCancel: { editorTarget = nil }
            )
        }
    }

    private func deleteGeneral(at offsets: IndexSet) {
        let toRemove = offsets.map { generals[$0].id }
        for id in toRemove {
            WalkthroughSettingsStore.deleteGeneral(id: id)
        }
        generals = WalkthroughSettingsStore.generals
    }
}

private struct GeneralRow: View {
    let section: GeneralSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(Theme.font.body.weight(.medium))
                .foregroundStyle(Theme.color.text.primary)
            if !section.introText.isEmpty {
                Text(section.introText)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Theme.spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemSectionRow: View {
    let iconName: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.spacing.sm) {
            Image(systemName: iconName)
                .foregroundStyle(Theme.color.text.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font.body.weight(.medium))
                    .foregroundStyle(Theme.color.text.primary)
                Text(subtitle)
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Theme.spacing.xxs)
    }
}

@MainActor
private struct GeneralEditorSheet: View {
    let initial: GeneralSection?
    let onSave: (GeneralSection) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var introText: String
    @FocusState private var titleFocused: Bool

    init(
        initial: GeneralSection?,
        onSave: @escaping (GeneralSection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: initial?.title ?? "")
        _introText = State(initialValue: initial?.introText ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.color.bg.surface.ignoresSafeArea()
                Form {
                    Section {
                        TextField("z. B. Morgenroutine", text: $title)
                            .focused($titleFocused)
                            .font(Theme.font.body)
                    } header: {
                        Text("Titel")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("Erscheint im Walkthrough-Header während dieses Abschnitts.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }

                    Section {
                        TextField(
                            "z. B. Wie ist dein Morgen heute angekommen?",
                            text: $introText,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                        .font(Theme.font.body)
                    } header: {
                        Text("Einleitung")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    } footer: {
                        Text("Wird per TTS als Opener vorgelesen, bevor das Mikrofon öffnet.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(initial == nil ? "Neuer Abschnitt" : "Abschnitt bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedIntro = introText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let section = GeneralSection(
                            id: initial?.id ?? UUID().uuidString,
                            title: trimmedTitle,
                            introText: trimmedIntro
                        )
                        onSave(section)
                        onCancel()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        introText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .onAppear {
                if initial == nil { titleFocused = true }
            }
        }
    }
}
