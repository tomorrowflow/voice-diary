import Foundation

// Resolves what one row of `WalkthroughOrderView` shows for a plan entry.
// Pure: the view keeps the localized copy for the system sections and the
// unknown-title fallback, the SF Symbol mapping and the SwiftUI rendering,
// and maps each case to them.
//
// A general entry carries only its id, so title and introduction come from
// the first `GeneralSection` with that id; when ids repeat, later ones are
// ignored. An id with no match is `missingGeneral`. An empty introduction
// is no introduction.

struct WalkthroughOrderRowContent: Equatable {
    enum Kind: Equatable {
        case general(title: String)
        /// A general entry whose id is not in the catalog; the view shows
        /// its localized unknown title.
        case missingGeneral
        case calendarEvents
        case voiceNote
    }

    let kind: Kind
    /// The general section's introduction, shown as the subtitle. Always
    /// nil for the system sections (the view supplies their copy) and for
    /// a missing or empty introduction.
    let introduction: String?

    init(entry: WalkthroughSection, generals: [GeneralSection]) {
        switch entry {
        case .general(let id):
            if let general = generals.first(where: { $0.id == id }) {
                kind = .general(title: general.title)
                introduction = general.introText.isEmpty ? nil : general.introText
            } else {
                kind = .missingGeneral
                introduction = nil
            }
        case .calendarEvents:
            kind = .calendarEvents
            introduction = nil
        case .voiceNote:
            kind = .voiceNote
            introduction = nil
        }
    }
}
