import AVFoundation
import SwiftUI

// In-app record button for dogfooding M2. Records → AAC-LC M4A under
// Application Support/VoiceDiary/driveby_seeds/{ISO timestamp}/audio.m4a.
// On stop, writes a metadata.json next to it.

@MainActor
public struct CaptureView: View {
    @State private var engine = AudioEngine()
    @State private var isRecording = false
    @State private var startedAt: Date?
    @State private var lastSeed: DriveBySeed?
    @State private var errorMessage: String?
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Button {
                    Task { await toggle() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.accentColor)
                            .frame(width: 160, height: 160)
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecording ? "Aufnahme beenden" : "Aufnahme starten")

                Text(timeString(elapsedSeconds))
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let seed = lastSeed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Letzter Seed")
                            .font(.headline)
                        Text(seed.audio_file_url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f s", seed.duration_seconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Drive-by")
        }
        .onDisappear { timer?.invalidate() }
    }

    private func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    private func start() async {
        errorMessage = nil
        do {
            let dir = try LocalStore.driveBySeedsDir()
                .appending(path: ISO8601DateFormatter().string(from: Date()), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let audio = dir.appending(path: "audio.m4a")
            try await engine.start(outputURL: audio)
            startedAt = Date()
            isRecording = true
            elapsedSeconds = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in elapsedSeconds += 1 }
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func stop() async {
        timer?.invalidate()
        timer = nil
        do {
            guard let url = try await engine.stop(), let started = startedAt else {
                isRecording = false
                return
            }
            let duration = Date().timeIntervalSince(started)
            let seed = DriveBySeed(
                seed_id: "seed-" + ISO8601DateFormatter().string(from: started),
                captured_at: started,
                duration_seconds: duration,
                language: "de",
                transcript: "",
                audio_file_url: url
            )
            try writeMetadata(seed: seed, alongside: url)
            lastSeed = seed
            isRecording = false
            startedAt = nil
        } catch {
            errorMessage = "\(error)"
            isRecording = false
        }
    }

    private func writeMetadata(seed: DriveBySeed, alongside audio: URL) throws {
        let json = audio.deletingLastPathComponent().appending(path: "metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(seed)
        try data.write(to: json, options: [.atomic, .completeFileProtection])
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
