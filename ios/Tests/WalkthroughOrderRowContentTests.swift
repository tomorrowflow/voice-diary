import Foundation
import Testing
@testable import VoiceDiary

// Lookup behind each row of WalkthroughOrderView. The view maps each kind
// to its localized title, system-section subtitle and SF Symbol; these
// tests pin which general (if any) a row resolves to and what it carries.

@Suite("WalkthroughOrderRowContent")
struct WalkthroughOrderRowContentTests {
    private static func general(
        _ id: String, title: String = "Morning", intro: String = "How was it?"
    ) -> GeneralSection {
        GeneralSection(id: id, title: title, introText: intro)
    }

    @Test("a general entry resolves to its title and introduction")
    func resolvesGeneral() {
        let content = WalkthroughOrderRowContent(
            entry: .general(id: "a"),
            generals: [Self.general("b", title: "Other"), Self.general("a")])

        #expect(content.kind == .general(title: "Morning"))
        #expect(content.introduction == "How was it?")
    }

    @Test("an empty catalog leaves a general entry missing")
    func emptyCatalog() {
        let content = WalkthroughOrderRowContent(entry: .general(id: "a"), generals: [])

        #expect(content.kind == .missingGeneral)
        #expect(content.introduction == nil)
    }

    @Test("an id absent from the catalog is missing, with no subtitle")
    func missingID() {
        let content = WalkthroughOrderRowContent(
            entry: .general(id: "gone"), generals: [Self.general("a")])

        #expect(content.kind == .missingGeneral)
        #expect(content.introduction == nil)
    }

    @Test("duplicate ids resolve to the first match's title and introduction")
    func duplicateIDs() {
        let generals = [
            Self.general("a", title: "First", intro: "First intro"),
            Self.general("a", title: "Second", intro: "Second intro"),
        ]
        let content = WalkthroughOrderRowContent(entry: .general(id: "a"), generals: generals)

        #expect(content.kind == .general(title: "First"))
        #expect(content.introduction == "First intro")
    }

    @Test("a duplicate id with an empty first introduction does not fall through to a later one")
    func duplicateWithEmptyFirstIntro() {
        let generals = [
            Self.general("a", title: "First", intro: ""),
            Self.general("a", title: "Second", intro: "Second intro"),
        ]
        let content = WalkthroughOrderRowContent(entry: .general(id: "a"), generals: generals)

        #expect(content.kind == .general(title: "First"))
        #expect(content.introduction == nil)
    }

    @Test("an empty introduction is no subtitle; a nonempty one is kept as written",
          arguments: [("", String?.none), ("Hello", "Hello"), (" ", " ")])
    func introduction(intro: String, expected: String?) {
        let content = WalkthroughOrderRowContent(
            entry: .general(id: "a"), generals: [Self.general("a", intro: intro)])

        #expect(content.introduction == expected)
    }

    @Test("a general with an empty title still resolves, not missing")
    func emptyTitle() {
        let content = WalkthroughOrderRowContent(
            entry: .general(id: "a"), generals: [Self.general("a", title: "")])

        #expect(content.kind == .general(title: ""))
    }

    @Test("system sections ignore unrelated generals and carry no introduction",
          arguments: [
            (WalkthroughSection.calendarEvents, WalkthroughOrderRowContent.Kind.calendarEvents),
            (.voiceNote, .voiceNote),
          ])
    func systemSections(entry: WalkthroughSection, expected: WalkthroughOrderRowContent.Kind) {
        let generals = [Self.general("a"), Self.general("b", title: "Evening", intro: "Hi")]

        for catalog in [[], generals] {
            let content = WalkthroughOrderRowContent(entry: entry, generals: catalog)

            #expect(content.kind == expected)
            #expect(content.introduction == nil)
        }
    }
}
