// What the bearer summary row in `ServerSettingsView` shows about a stored
// token, projected from the token string alone. The view keeps the Keychain
// read, the localized "(empty)" label and the exact
// `len=<count> · …<suffix>` rendering. Counts and suffixes are in
// Characters (grapheme clusters), and short tokens are shown whole, so no
// masking policy lives here.

enum BearerSummaryProjection: Equatable {
    /// No token stored.
    case empty
    /// A token of `count` Characters whose last four Characters are `suffix`.
    case present(count: Int, suffix: String)

    init(_ token: String) {
        if token.isEmpty {
            self = .empty
        } else {
            self = .present(count: token.count, suffix: String(token.suffix(4)))
        }
    }
}
