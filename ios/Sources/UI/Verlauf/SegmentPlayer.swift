import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Single-row audio player for the Verlauf detail screen. Holds one
/// `AVAudioPlayer` at a time and exposes which file URL is currently
/// playing so each `SegmentRow` can flip its play/pause icon. Playing
/// a different segment automatically stops the previous one.
@MainActor
final class SegmentPlayer: ObservableObject {
    @Published private(set) var playingURL: URL?

    private var player: AVAudioPlayer?
    private var delegateProxy: DelegateProxy?

    func toggle(url: URL) {
        if playingURL == url, let player, player.isPlaying {
            player.pause()
            playingURL = nil
            return
        }
        // Configure the audio session for playback. Spoken-word category
        // ducks to the speaker even when the silent switch is on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

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
            self.playingURL = url
        } catch {
            self.player = nil
            self.delegateProxy = nil
            self.playingURL = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        delegateProxy = nil
        playingURL = nil
    }

    private func didFinish() {
        playingURL = nil
        player = nil
        delegateProxy = nil
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
        let total = Int(seconds.rounded())
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
}
