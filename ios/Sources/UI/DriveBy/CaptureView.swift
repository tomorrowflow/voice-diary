import AVFoundation
import SwiftUI

// In-app record button for dogfooding M2. Records → AAC M4A under
// Application Support/VoiceDiary/driveby_seeds/{ISO timestamp}/audio.m4a.
// On stop, the audio is transcribed locally via Parakeet v3 and the
// transcript + metadata are written to metadata.json next to the M4A.

@MainActor
public struct CaptureView: View {
    @State private var engine = AudioEngine()
    @State private var isRecording = false
    @State private var startedAt: Date?
    @State private var lastSeed: DriveBySeed?
    @State private var errorMessage: String?
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var statusLine: String = ""
    @State private var modelState: ParakeetManager.LoadState = .idle

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Theme.color.bg.surface.ignoresSafeArea()

                VStack(spacing: Theme.spacing.xxl) {
                    Spacer()

                    Button {
                        Task { await toggle() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isRecording
                                      ? Theme.color.status.destructive
                                      : Theme.color.fg.primary)
                                .frame(width: 160, height: 160)
                                .shadow(color: Theme.color.bg.overlay, radius: 20, y: 8)
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(Theme.color.text.inverse)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isRecording ? "Aufnahme beenden" : "Aufnahme starten")

                    Text(timeString(elapsedSeconds))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.color.text.secondary)

                    if !statusLine.isEmpty {
                        Text(statusLine)
                            .font(Theme.font.callout)
                            .foregroundStyle(Theme.color.text.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.spacing.md)
                    }

                    if let seed = lastSeed {
                        SeedSummaryCard(seed: seed)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.font.footnote)
                            .foregroundStyle(Theme.color.status.destructive)
                            .padding(.horizontal, Theme.spacing.md)
                    }

                    Spacer()
                }
                .padding(.horizontal, Theme.spacing.md)
            }
            .navigationTitle("Drive-by")
            .task {
                // Trigger Parakeet model load lazily as soon as the user
                // opens this tab — first launch downloads ~1.2 GB.
                await ParakeetManager.shared.warmUp()
                modelState = await ParakeetManager.shared.loadState
                if case .loading = modelState {
                    statusLine = "Lade Sprachmodell — beim ersten Start ~1,2 GB."
                } else if case .failed(let msg) = modelState {
                    statusLine = "Sprachmodell konnte nicht geladen werden."
                    errorMessage = msg
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    private func start() async {
        errorMessage = nil
        statusLine = ""
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
        statusLine = "Transkribiere …"
        do {
            guard let url = try await engine.stop(), let started = startedAt else {
                isRecording = false
                statusLine = ""
                return
            }
            let duration = Date().timeIntervalSince(started)
            isRecording = false
            startedAt = nil

            // Transcribe locally. If Parakeet isn't ready yet (still
            // downloading on first launch) we persist the seed without a
            // transcript — the server's Whisper sidecar will produce one
            // on ingest.
            var transcript: ParakeetManager.Transcript?
            do {
                transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
            } catch {
                Log.audio.warning("Parakeet transcript skipped: \(String(describing: error), privacy: .public)")
            }

            let seed = DriveBySeed(
                seed_id: "seed-" + ISO8601DateFormatter().string(from: started),
                captured_at: started,
                duration_seconds: duration,
                language: transcript?.language ?? "de",
                transcript: transcript?.text ?? "",
                audio_file_url: url
            )
            try writeMetadata(seed: seed, alongside: url)
            lastSeed = seed
            statusLine = transcript == nil
                ? "Aufnahme gespeichert. Transkript folgt beim Server-Upload."
                : "Aufnahme + Transkript gespeichert."
        } catch {
            errorMessage = "\(error)"
            statusLine = ""
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

private struct SeedSummaryCard: View {
    let seed: DriveBySeed

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xs) {
            Text("Letzter Seed")
                .font(Theme.font.headline)
                .foregroundStyle(Theme.color.text.primary)
            Text(seed.audio_file_url.lastPathComponent)
                .font(Theme.font.monoCaption)
                .foregroundStyle(Theme.color.text.secondary)
            Text("\(String(format: "%.1f", seed.duration_seconds)) s · \(seed.language)")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
            if !seed.transcript.isEmpty {
                Text(seed.transcript)
                    .font(Theme.font.callout)
                    .foregroundStyle(Theme.color.text.primary)
                    .padding(.top, Theme.spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
        .padding(.horizontal, Theme.spacing.md)
    }
}
