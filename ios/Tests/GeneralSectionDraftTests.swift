import Foundation
import Testing
@testable import VoiceDiary

@Suite("GeneralSectionDraft")
struct GeneralSectionDraftTests {

    // MARK: - canSave

    @Test("empty title disables saving")
    func emptyTitle() {
        let draft = GeneralSectionDraft(title: "", introText: "Intro", followUpEnabled: false)
        #expect(!draft.canSave)
    }

    @Test("empty intro disables saving")
    func emptyIntro() {
        let draft = GeneralSectionDraft(title: "Title", introText: "", followUpEnabled: false)
        #expect(!draft.canSave)
    }

    @Test("whitespace-only title disables saving")
    func whitespaceTitle() {
        let draft = GeneralSectionDraft(title: " \t\n ", introText: "Intro", followUpEnabled: false)
        #expect(!draft.canSave)
    }

    @Test("whitespace-only intro disables saving")
    func whitespaceIntro() {
        let draft = GeneralSectionDraft(title: "Title", introText: "\n  \n", followUpEnabled: false)
        #expect(!draft.canSave)
    }

    @Test("non-empty title and intro enable saving")
    func bothFilled() {
        let draft = GeneralSectionDraft(title: "Title", introText: "Intro", followUpEnabled: false)
        #expect(draft.canSave)
    }

    @Test("follow-up flag does not affect saving")
    func followUpIrrelevantToCanSave() {
        let off = GeneralSectionDraft(title: "", introText: "", followUpEnabled: false)
        let on = GeneralSectionDraft(title: "", introText: "", followUpEnabled: true)
        #expect(!off.canSave)
        #expect(!on.canSave)
    }

    // MARK: - normalization

    @Test("trims outer whitespace and newlines from title and intro")
    func trimsOuter() {
        let draft = GeneralSectionDraft(
            title: "  \n Morning routine \t",
            introText: "\n\n How did it land? \n ",
            followUpEnabled: false
        )
        let section = draft.section(id: "id-1")
        #expect(section.title == "Morning routine")
        #expect(section.introText == "How did it land?")
    }

    @Test("preserves internal spaces, newlines, punctuation and Unicode")
    func preservesInterior() {
        let draft = GeneralSectionDraft(
            title: "  Café  “Frühstück” – 朝ごはん 🌅  ",
            introText: " Wie war dein Morgen?\n\nZweite  Zeile, ok! ",
            followUpEnabled: true
        )
        let section = draft.section(id: "id-2")
        #expect(section.title == "Café  “Frühstück” – 朝ごはん 🌅")
        #expect(section.introText == "Wie war dein Morgen?\n\nZweite  Zeile, ok!")
    }

    @Test("a draft that can save yields non-empty normalized text")
    func enablementMatchesSavedValues() {
        let inputs: [(String, String)] = [
            ("", ""), (" ", "x"), ("x", " "), ("\n", "\n"),
            ("a", "b"), ("  a  ", "\tb\n"), ("é", "🌅")
        ]
        for (title, intro) in inputs {
            let draft = GeneralSectionDraft(title: title, introText: intro, followUpEnabled: false)
            let section = draft.section(id: "id")
            #expect(draft.canSave == (!section.title.isEmpty && !section.introText.isEmpty))
        }
    }

    // MARK: - identity and flags

    @Test("section uses the explicit id it is given")
    func explicitID() {
        let draft = GeneralSectionDraft(title: "T", introText: "I", followUpEnabled: false)
        #expect(draft.section(id: "explicit-id").id == "explicit-id")
    }

    @Test("editing an existing section keeps its id when saved with that id")
    func editKeepsID() {
        let existing = GeneralSection(id: "existing", title: "Old", introText: "Old intro", followUpEnabled: true)
        var draft = GeneralSectionDraft(editing: existing)
        draft.title = "New"
        let saved = draft.section(id: existing.id)
        #expect(saved.id == "existing")
        #expect(saved.title == "New")
        #expect(saved.introText == "Old intro")
        #expect(saved.followUpEnabled)
    }

    @Test("follow-up flag is carried through exactly")
    func followUpFlag() {
        let on = GeneralSectionDraft(title: "T", introText: "I", followUpEnabled: true)
        let off = GeneralSectionDraft(title: "T", introText: "I", followUpEnabled: false)
        #expect(on.section(id: "a").followUpEnabled)
        #expect(!off.section(id: "a").followUpEnabled)
    }

    // MARK: - initial values

    @Test("new draft starts empty with follow-up off")
    func newDraftDefaults() {
        let draft = GeneralSectionDraft(editing: nil)
        #expect(draft.title == "")
        #expect(draft.introText == "")
        #expect(!draft.followUpEnabled)
        #expect(!draft.canSave)
    }

    @Test("editing draft starts from the section's stored values untrimmed")
    func editDraftInitialValues() {
        let existing = GeneralSection(id: "e", title: " Padded ", introText: "Intro\n", followUpEnabled: true)
        let draft = GeneralSectionDraft(editing: existing)
        #expect(draft.title == " Padded ")
        #expect(draft.introText == "Intro\n")
        #expect(draft.followUpEnabled)
        #expect(draft.canSave)
    }
}
