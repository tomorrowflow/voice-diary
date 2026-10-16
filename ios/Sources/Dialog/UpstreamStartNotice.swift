import Foundation

/// The walkthrough start notice (UFH-08) together with the start that owns
/// it. A `/health` answer or a six-second timer can arrive after the user
/// cancelled or began again; each holds the token of the start that spawned
/// it and may only publish or clear while that start is still the current
/// one. Kept apart from `WalkthroughCoordinator` so the race rules are
/// unit-testable without audio, TTS or the network.
public struct UpstreamStartNotice: Equatable, Sendable {
    /// The text to show; nil when there is no notice.
    public private(set) var message: String?
    /// The start whose results count; nil after `reset()`.
    private var owner: UUID?

    public init() {}

    /// A new start begins: its token is the only one that counts from now,
    /// and the previous start's notice is gone.
    public mutating func begin() -> UUID {
        let token = UUID()
        owner = token
        message = nil
        return token
    }

    /// The walkthrough was cancelled: drop the notice and make every result
    /// still in flight stale.
    public mutating func reset() {
        owner = nil
        message = nil
    }

    public func isCurrent(_ token: UUID) -> Bool { owner == token }

    /// Show `message` for the start that owns `token`. Returns false, and
    /// changes nothing, when that start is no longer current.
    @discardableResult
    public mutating func publish(_ message: String, for token: UUID) -> Bool {
        guard owner == token else { return false }
        self.message = message
        return true
    }

    /// Clear the notice the start that owns `token` published. A stale token
    /// never clears a newer start's notice, even if the text is identical.
    public mutating func clear(for token: UUID) {
        guard owner == token else { return }
        message = nil
    }
}
