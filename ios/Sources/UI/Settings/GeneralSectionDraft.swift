import Foundation

/// In-progress edit of a `GeneralSection`. Owns the save rule and the
/// whitespace normalization so the editor's Save enablement and the section
/// it persists can't drift apart.
struct GeneralSectionDraft: Equatable, Sendable {
    var title: String
    var introText: String
    var followUpEnabled: Bool

    init(title: String = "", introText: String = "", followUpEnabled: Bool = false) {
        self.title = title
        self.introText = introText
        self.followUpEnabled = followUpEnabled
    }

    /// Seeds the draft from an existing section, or empty defaults for a new one.
    init(editing section: GeneralSection?) {
        self.init(
            title: section?.title ?? "",
            introText: section?.introText ?? "",
            followUpEnabled: section?.followUpEnabled ?? false
        )
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedIntro: String {
        introText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both fields need visible content once outer whitespace is trimmed.
    var canSave: Bool {
        !normalizedTitle.isEmpty && !normalizedIntro.isEmpty
    }

    /// The section to persist, with trimmed title and intro and the given id.
    func section(id: String) -> GeneralSection {
        GeneralSection(
            id: id,
            title: normalizedTitle,
            introText: normalizedIntro,
            followUpEnabled: followUpEnabled
        )
    }
}
