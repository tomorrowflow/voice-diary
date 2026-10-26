import Foundation

/// A documented refusal of `retry-transcription` (FTR-02, ADR 0007). Every
/// one is answered before the server changes anything.
public enum TranscriptionRecoveryRefusal: Equatable, Sendable {
    case sessionNotFound
    case segmentNotFound
    /// The segment is no longer `failed`; the status shows what it is now.
    case segmentNotFailed
    /// The recording is no longer on the server: the action is gone.
    case segmentAudioMissing
    /// Another run holds the session (upload, analysis retry, sweep or
    /// another segment's recovery).
    case sessionBusy
    case whisperUnavailable(retryAfter: TimeInterval?)

    /// nil when `error` is not one of the documented refusals, which includes
    /// every transport error: a timeout or lost connection is an unknown
    /// outcome, not a refusal.
    init?(_ error: any Error) {
        guard case ServerClientError.http(let status, let detail, let failure) = error else { return nil }
        let code = failure.code
            ?? detail.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) }
        switch (status, code) {
        case (404, "session_not_found"): self = .sessionNotFound
        case (404, "segment_not_found"): self = .segmentNotFound
        case (409, "segment_not_failed"): self = .segmentNotFailed
        case (409, "segment_audio_missing"): self = .segmentAudioMissing
        case (409, "session_busy"): self = .sessionBusy
        case (503, "whisper_unavailable"): self = .whisperUnavailable(retryAfter: failure.retryAfter)
        default: return nil
        }
    }
}

/// Starts and follows transcription recoveries for one session's screen
/// (ADR 0005, 0007), in the style of `AnalysisRetrier`: the IO is injected
/// closures, so tests drive it without a server.
///
/// - Only `start(segmentID:)` ever sends a recovery request, once per call,
///   and nothing but the screen calls it. A call is ignored while an
///   attempt is in flight.
/// - A timeout, a lost connection or an undecodable answer is an *unknown
///   outcome*: the status is read, never the request repeated. If the
///   segment is still `failed` the action is simply offered again.
/// - While the screen is visible the status is read on `refreshInterval`
///   until no segment is `transcribing`. `screenLeft()` stops that and
///   `screenAppeared()` reads once and resumes. A status read is never a
///   retry. Recovery is foreground-only: nothing here outlives the screen.
public actor TranscriptionRecoveryRunner {
    /// A few seconds, as the PRD proposes; an injected constant, not a setting.
    public static let defaultRefreshInterval: TimeInterval = 3

    /// The IO the runner needs, injectable so tests drive it without a server.
    struct Dependencies: Sendable {
        var retry: @Sendable (_ sessionID: String, _ segmentID: String) async throws
            -> ServerClient.SessionStatusResponse
        var status: @Sendable (_ sessionID: String) async throws -> ServerClient.SessionStatusResponse?
        var sleep: @Sendable (_ seconds: TimeInterval) async throws -> Void

        static let live = Dependencies(
            retry: { try await ServerClient.shared.retryTranscription(sessionID: $0, segmentID: $1) },
            status: { try await ServerClient.shared.sessionStatus(sessionID: $0) },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
    }

    /// What the screen renders, published through `onChange`.
    struct State: Equatable, Sendable {
        /// The last status read or returned by the server; nil before the
        /// first.
        var status: ServerClient.SessionStatusResponse?
        /// The segment this screen asked to recover, from the tap until its
        /// outcome is known.
        var attemptSegmentID: String?
        /// Segments the server said have no recording left: no action.
        var audioMissing: Set<String> = []
        /// Why the last tap on a segment was refused, so the screen can
        /// explain it. A refusal never changes the segment's own state.
        var notices: [String: TranscriptionRecoveryRefusal] = [:]

        /// The action for `segmentID`: hidden until a status is known.
        func action(for segmentID: String, whisper: WhisperHealth) -> TranscriptionRecoveryAction {
            guard let segments = status?.segments,
                  let segment = segments.first(where: { $0.segment_id == segmentID }),
                  !audioMissing.contains(segmentID)
            else { return .hidden }
            let otherRunning = segments.contains { $0.segment_id != segmentID && $0.state == .transcribing }
            let otherAttempt = attemptSegmentID.map { $0 != segmentID } ?? false
            return TranscriptionRecoveryPolicy.action(
                segment: segment.state,
                recoverable: segment.recoverable,
                whisper: whisper,
                attemptInFlight: attemptSegmentID == segmentID,
                siblingTranscribing: otherRunning || otherAttempt)
        }
    }

    private let sessionID: String
    private let deps: Dependencies
    private let refreshInterval: TimeInterval
    private let onChange: @Sendable (State) -> Void

    private(set) var state = State() {
        didSet { if state != oldValue { onChange(state) } }
    }
    private var visible = false
    /// The request is on the wire; a status read meanwhile must not end the
    /// attempt, because the server may not have accepted it yet.
    private var submitting = false
    /// An unknown outcome whose status read has not succeeded yet.
    private var readPending = false
    /// Bumped when a request goes out, when it is answered and when the screen
    /// is left. A status read that began under an older epoch may predate
    /// what the runner knows now, so its answer is dropped instead of
    /// overwriting it.
    private var readEpoch = 0
    private var followTask: Task<Void, Never>?
    private var followGeneration = 0

    init(
        sessionID: String,
        deps: Dependencies = .live,
        refreshInterval: TimeInterval = TranscriptionRecoveryRunner.defaultRefreshInterval,
        onChange: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.deps = deps
        self.refreshInterval = refreshInterval
        self.onChange = onChange
    }

    // --- screen lifecycle ----------------------------------------------

    /// The screen became visible: reconcile with the server and, if a
    /// segment is still `transcribing`, keep refreshing. Never sends a
    /// recovery request.
    func screenAppeared() async {
        visible = true
        await read()
        startFollowingIfNeeded()
    }

    /// The screen was left: stop refreshing. An attempt already accepted
    /// keeps running on the server; `screenAppeared()` finds its outcome.
    func screenLeft() {
        visible = false
        followTask?.cancel()
        followTask = nil
        followGeneration += 1
        // A poll still on the wire is about to be superseded by the read on
        // return; its late answer must not overwrite that one.
        readEpoch += 1
    }

    /// Waits for the refresh loop, if one is running. For tests.
    func settled() async {
        await followTask?.value
    }

    // --- the tap -------------------------------------------------------

    /// One explicit tap on "Erneut transkribieren": one request. Ignored
    /// while an attempt is in flight or when the recording is known to be
    /// gone.
    func start(segmentID: String) async {
        guard state.attemptSegmentID == nil, !submitting, !state.audioMissing.contains(segmentID) else { return }
        state.attemptSegmentID = segmentID
        state.notices[segmentID] = nil
        submitting = true
        readEpoch += 1
        do {
            let accepted = try await deps.retry(sessionID, segmentID)
            submitting = false
            readEpoch += 1
            apply(accepted)
        } catch {
            submitting = false
            readEpoch += 1
            await settle(afterFailure: error, segmentID: segmentID)
        }
        startFollowingIfNeeded()
    }

    private func settle(afterFailure error: any Error, segmentID: String) async {
        if case ServerClientError.notConfigured = error {
            // Never sent: nothing happened, nothing to read.
            state.attemptSegmentID = nil
            return
        }
        guard let refusal = TranscriptionRecoveryRefusal(error) else {
            // Unknown outcome: the server may have accepted it. Read, never resubmit.
            Log.backend.info("transcription recovery outcome unknown for \(segmentID, privacy: .public): \(String(describing: error), privacy: .public)")
            readPending = true
            await read()
            return
        }
        switch refusal {
        case .segmentAudioMissing:
            state.audioMissing.insert(segmentID)
            state.attemptSegmentID = nil
        case .segmentNotFailed:
            // It moved on without this tap; the status says where to.
            readPending = true
            await read()
        case .sessionNotFound, .segmentNotFound, .sessionBusy, .whisperUnavailable:
            state.notices[segmentID] = refusal
            state.attemptSegmentID = nil
        }
    }

    // --- reading the status --------------------------------------------

    private func apply(_ status: ServerClient.SessionStatusResponse) {
        state.status = status
        readPending = false
        guard !submitting, let attempt = state.attemptSegmentID else { return }
        let current = status.segments.first { $0.segment_id == attempt }?.state
        if current != .transcribing { state.attemptSegmentID = nil }
    }

    /// A status read is never a retry. A failed read changes nothing.
    private func read() async {
        let epoch = readEpoch
        do {
            let answer = try await deps.status(sessionID)
            guard epoch == readEpoch else { return }
            if let status = answer {
                apply(status)
            } else if !submitting {
                // The server forgot the session: nothing left to follow.
                readPending = false
                state.attemptSegmentID = nil
            }
        } catch {
            Log.backend.debug("transcription recovery status read failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var shouldFollow: Bool {
        readPending || state.status?.segments.contains { $0.state == .transcribing } == true
    }

    private func startFollowingIfNeeded() {
        guard visible, followTask == nil, shouldFollow else { return }
        followGeneration += 1
        let generation = followGeneration
        followTask = Task { await self.follow(generation: generation) }
    }

    /// Reads the status every `refreshInterval` while this loop is the
    /// current one (leaving the screen starts a new generation, so a read
    /// that was in flight at that moment cannot revive an old loop).
    private func follow(generation: Int) async {
        while followGeneration == generation, shouldFollow {
            do { try await deps.sleep(refreshInterval) } catch { break }
            guard followGeneration == generation else { break }
            await read()
        }
        if followGeneration == generation { followTask = nil }
    }
}
