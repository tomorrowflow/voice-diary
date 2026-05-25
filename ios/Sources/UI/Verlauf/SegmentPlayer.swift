import AVFoundation
import Foundation
import SwiftUI

/// Single-row audio player for the Verlauf detail screen. Holds one
/// `AVAudioPlayer` at a time and exposes which file URL is currently
/// loaded (`activeURL`), whether it's playing, and the live playback
/// position so a `SegmentRow` / `NoteRow` can render a voice-memo-style
/// scrubber. Playing a different segment automatically stops the
/// previous one.
///
/// `@Observable` (not `ObservableObject`) so the per-tick `currentTime`
/// updates only re-render the views that actually read it — the active
/// row's scrubber — instead of the whole detail screen.
@MainActor
@Observable
final class SegmentPlayer {
    /// The file currently loaded in the player. Stays set while paused
    /// or after playback finishes (so the scrubber stays visible on the
    /// selected row); cleared only by `stop()` or loading another file.
    private(set) var activeURL: URL?
    /// Whether `activeURL` is playing right now (false while paused /
    /// finished).
    private(set) var isPlaying: Bool = false
    /// Live playback head, in seconds. Driven by the ticker while playing.
    private(set) var currentTime: TimeInterval = 0
    /// Total length of `activeURL`, in seconds (from the loaded player).
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegateProxy: DelegateProxy?
    @ObservationIgnored private var ticker: Timer?
    /// Set when a scrub starts mid-playback so the release resumes.
    @ObservationIgnored private var resumeAfterScrub = false

    /// When false, playback leaves the audio session untouched — the
    /// caller already owns an appropriate category (the walkthrough's
    /// `.playAndRecord`, which both records the wake-word mic and plays
    /// to the speaker). Verlauf leaves this true so a standalone tap ducks
    /// to the speaker via `.playback` / `.spokenAudio` even with the
    /// silent switch on.
    @ObservationIgnored private let managesSession: Bool

    /// Fired once on *natural* playback completion — not on pause, stop,
    /// or loading another file. The walkthrough's note review sets this to
    /// open the wake-word window only after the seed has played through.
    @ObservationIgnored var onNaturalFinish: (@MainActor () -> Void)?

    init(managesSession: Bool = true) {
        self.managesSession = managesSession
    }

    /// Backward-compatible accessor: the URL that is *actively playing
    /// right now*, or `nil` when paused/stopped. Distinct from
    /// `activeURL`, which stays set while paused. Used by the
    /// walkthrough's note-replay button.
    var playingURL: URL? { isPlaying ? activeURL : nil }

    /// Play/pause toggle. Loads `url` fresh if it isn't the active file,
    /// otherwise pauses or resumes in place (resume keeps the position).
    func toggle(url: URL) {
        if activeURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTicker()
            } else {
                activateSession()
                player.play()
                isPlaying = true
                startTicker()
            }
            return
        }

        activateSession()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let proxy = DelegateProxy { [weak self] in
                Task { @MainActor in self?.didFinish() }
            }
            p.delegate = proxy
            p.prepareToPlay()
            p.play()
            self.player = p
            self.delegateProxy = proxy
            self.activeURL = url
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = true
            startTicker()
        } catch {
            resetState()
        }
    }

    /// Move the playback head. Clamps into `[0, duration]`. Safe to call
    /// while playing or paused; the next ticker frame continues from here.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Begin a drag-scrub: pause playback so the user hears silence while
    /// dragging the knob, remembering whether to resume on release.
    func beginScrubbing() {
        guard let player, player.isPlaying else {
            resumeAfterScrub = false
            return
        }
        resumeAfterScrub = true
        player.pause()
        isPlaying = false
        stopTicker()
    }

    /// End a drag-scrub: jump to the dragged position and resume playback
    /// only if it was playing when the drag began.
    func endScrubbing(to time: TimeInterval) {
        seek(to: time)
        guard resumeAfterScrub else { return }
        resumeAfterScrub = false
        activateSession()
        player?.play()
        isPlaying = true
        startTicker()
    }

    func stop() {
        stopTicker()
        player?.stop()
        resetState()
    }

    // MARK: - Internals

    private func activateSession() {
        guard managesSession else { return }
        // Spoken-word category ducks to the speaker even when the silent
        // switch is on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func didFinish() {
        stopTicker()
        // Keep the file selected so the scrubber stays visible; rewind to
        // the start so a second tap replays from the top.
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        onNaturalFinish?()
    }

    private func resetState() {
        player = nil
        delegateProxy = nil
        activeURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        stopTicker()
        // 20 Hz is plenty for a smooth scrubber knob without churn.
        // `.common` mode keeps it firing while the list is being scrolled.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player, player.isPlaying else { return }
        currentTime = player.currentTime
    }

    /// One-shot duration probe for an .m4a on disk. Cheap (~ms) — pulls
    /// the duration atom from the file header without decoding samples.
    static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let cm = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(cm)
            return seconds.isFinite ? seconds : nil
        } catch {
            return nil
        }
    }

    /// "0:42" / "12:03" / "1:02:34" formatter for compact rows.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// AVAudioPlayerDelegate is `@objc`, so we can't conform an actor /
/// MainActor class to it directly. This non-isolated proxy bounces
/// the finish callback back to the main actor.
private final class DelegateProxy: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        // Treat a decode failure as a finish so a waiter (the walkthrough's
        // note-playback continuation) can't hang on a player that will
        // never emit didFinishPlaying.
        onFinish()
    }
}
