import AVFoundation
import SwiftUI

/// Voice-reference recording screen for Voxtral cloning. Presented
/// from `VoiceSettingsView` when the user taps "Eigene Stimme
/// aufnehmen" under a language section.
///
/// State machine, top to bottom:
///   1. idle      — big record button, language indicator, hint text.
///   2. recording — VU meter + elapsed time, stop button.
///   3. recorded  — preview button + name field. Kicks off Parakeet
///                  transcription on entry; flips to .ready when done.
///   4. ready     — editable transcript + name + Speichern button.
///   5. uploading — spinner + "Hochladen…".
///   6. error     — message + retry/back.
///
/// After a successful upload, dismisses back to `VoiceSettingsView`
/// which refreshes its catalog and surfaces the new voice in the
/// picker.

@MainActor
public struct VoxtralCloneRecorderView: View {
    public enum Language: String, Sendable {
        case de = "DE"
        case en = "EN"

        var displayName: String {
            switch self {
            case .de: return "Deutsch"
            case .en: return "English"
            }
        }
    }

    private enum Step: Equatable {
        case idle
        case recording
        case recorded
        case transcribing
        case ready
        case uploading
    }

    public let language: Language

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceReferenceRecorder()
    @StateObject private var catalog = VoiceCatalogClient.shared

    @State private var step: Step = .idle
    @State private var recordedURL: URL?
    @State private var name: String = ""
    @State private var refText: String = ""
    @State private var errorMessage: String?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var isPreviewing: Bool = false

    public init(language: Language) {
        self.language = language
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Stimme aufnehmen")

                ScrollView {
                    VStack(spacing: Theme.spacing.md) {
                        languageCard
                        recordingCard
                        if step == .ready || step == .uploading {
                            metadataCard
                        }
                        if let errorMessage {
                            errorCard(errorMessage)
                        }
                        hintCard
                    }
                    .padding(.horizontal, Theme.spacing.md)
                    .padding(.vertical, Theme.spacing.md)
                }
            }
        }
        .navigationBarHidden(true)
        .onDisappear {
            recorder.cancel()
            previewPlayer?.stop()
        }
    }

    // MARK: - Cards

    private var languageCard: some View {
        HStack(spacing: Theme.spacing.sm) {
            Image(systemName: "globe")
                .foregroundStyle(Theme.color.text.subdued)
            Text("Sprache: \(language.displayName)")
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
            Spacer()
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
    }

    private var recordingCard: some View {
        VStack(spacing: Theme.spacing.md) {
            switch step {
            case .idle:
                idleRecordingBody
            case .recording:
                recordingBody
            case .recorded, .transcribing, .ready, .uploading:
                recordedBody
            }
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.bg.container)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
        )
    }

    private var idleRecordingBody: some View {
        VStack(spacing: Theme.spacing.md) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.color.text.link)

            Text("Lies einen Satz oder zwei laut vor — 3 bis 15 Sekunden reichen.")
                .font(Theme.font.body)
                .foregroundStyle(Theme.color.text.primary)
                .multilineTextAlignment(.center)

            Button {
                Task { await startRecording() }
            } label: {
                Label("Aufnahme starten", systemImage: "record.circle")
            }
            .buttonStyle(DSButtonStyle(variant: .primary, size: .md, fullWidth: true))
        }
    }

    private var recordingBody: some View {
        VStack(spacing: Theme.spacing.md) {
            // VU meter — a horizontal bar that fills with recorder.level
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous)
                    .fill(Theme.color.bg.surface)
                    .frame(height: 12)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous)
                        .fill(Theme.color.text.link)
                        .frame(width: proxy.size.width * CGFloat(recorder.level), height: 12)
                        .animation(.linear(duration: 0.08), value: recorder.level)
                }
                .frame(height: 12)
            }

            Text(timeString(recorder.elapsed))
                .font(Theme.font.monoBody)
                .foregroundStyle(Theme.color.text.primary)

            Text("Maximal \(Int(VoiceReferenceRecorder.maxDurationSeconds)) Sekunden.")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)

            Button {
                stopRecording()
            } label: {
                Label("Stopp", systemImage: "stop.circle.fill")
            }
            .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
        }
    }

    private var recordedBody: some View {
        VStack(spacing: Theme.spacing.md) {
            Image(systemName: step == .ready || step == .uploading ? "checkmark.circle.fill" : "waveform.circle")
                .font(.system(size: 56))
                .foregroundStyle(step == .ready || step == .uploading ? Theme.color.status.success : Theme.color.text.link)

            Text(recordedCaption)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)

            HStack(spacing: Theme.spacing.sm) {
                Button {
                    Task { await togglePreview() }
                } label: {
                    Label(isPreviewing ? "Stopp" : "Anhören",
                          systemImage: isPreviewing ? "stop.fill" : "play.fill")
                }
                .buttonStyle(DSButtonStyle(variant: .secondary, size: .md, fullWidth: true))
                .disabled(recordedURL == nil)

                Button {
                    resetToIdle()
                } label: {
                    Label("Neu", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(DSButtonStyle(variant: .outline, size: .md, fullWidth: true))
                .disabled(step == .uploading)
            }
        }
    }

    private var recordedCaption: String {
        switch step {
        case .recorded:     return "Aufnahme gespeichert. Wird transkribiert …"
        case .transcribing: return "Transkription läuft …"
        case .ready:        return "Bereit. Trag Name + Transkript ein und speichere."
        case .uploading:    return "Wird hochgeladen …"
        default:            return ""
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            Text("Name dieser Stimme")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
            TextField("z.B. Mein Hochdeutsch", text: $name)
                .textInputAutocapitalization(.sentences)
                .font(Theme.font.body)
                .padding(Theme.spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.bg.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
                )
                .disabled(step == .uploading)

            Text("Transkript der Aufnahme")
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.subdued)
                .padding(.top, Theme.spacing.xs)
            Text("Verbessert die Klon-Qualität. Korrigiere falls Parakeet sich verhört hat.")
                .font(Theme.font.caption2)
                .foregroundStyle(Theme.color.text.subdued)
            TextEditor(text: $refText)
                .font(Theme.font.body)
                .frame(minHeight: 80)
                .padding(Theme.spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .fill(Theme.color.bg.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous)
                        .strokeBorder(Theme.color.border.subdued, lineWidth: 1)
                )
                .scrollContentBackground(.hidden)
                .disabled(step == .uploading)

            Button {
                Task { await upload() }
            } label: {
                Label(step == .uploading ? "Wird gespeichert …" : "Speichern",
                      systemImage: "checkmark.circle")
            }
            .buttonStyle(DSButtonStyle(variant: .primary, size: .md, fullWidth: true))
            .disabled(step == .uploading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.color.status.destructive)
            Text(message)
                .font(Theme.font.caption)
                .foregroundStyle(Theme.color.text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .fill(Theme.color.status.destructive.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous)
                .strokeBorder(Theme.color.status.destructive.opacity(0.30), lineWidth: 1)
        )
    }

    private var hintCard: some View {
        Text("Die Aufnahme bleibt auf deinem Server (Tailscale-only). Die Stimme erscheint danach in der Stimmenauswahl unter \(language.displayName).")
            .font(Theme.font.caption)
            .foregroundStyle(Theme.color.text.subdued)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func startRecording() async {
        errorMessage = nil
        do {
            try await recorder.start()
            step = .recording
        } catch {
            errorMessage = String(describing: error)
            step = .idle
        }
    }

    private func stopRecording() {
        do {
            let url = try recorder.stop()
            recordedURL = url
            step = .recorded
            Task { await runTranscription(url: url) }
        } catch {
            errorMessage = String(describing: error)
            step = .idle
        }
    }

    private func runTranscription(url: URL) async {
        step = .transcribing
        do {
            let transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
            refText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Pre-fill name with the first few words of the transcript so
            // the user has something to edit rather than an empty field.
            if name.isEmpty {
                let firstWords = refText.split(separator: " ").prefix(3).joined(separator: " ")
                name = firstWords.isEmpty ? "Eigene Stimme" : "Stimme: \(firstWords)"
            }
            step = .ready
        } catch {
            // Transcription failed (Parakeet not loaded, silent
            // recording, etc.). Still let the user proceed — ref_text
            // is optional and they can type it manually.
            refText = ""
            if name.isEmpty { name = "Eigene Stimme" }
            step = .ready
        }
    }

    private func togglePreview() async {
        if isPreviewing {
            previewPlayer?.stop()
            isPreviewing = false
            return
        }
        guard let url = recordedURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            previewPlayer = player
            player.prepareToPlay()
            isPreviewing = true
            player.play()
            // Auto-clear the preview flag after the clip ends.
            let duration = player.duration
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            isPreviewing = false
        } catch {
            errorMessage = "Wiedergabe fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func resetToIdle() {
        recorder.cancel()
        if let url = recordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        name = ""
        refText = ""
        errorMessage = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewing = false
        step = .idle
    }

    private func upload() async {
        guard let url = recordedURL else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        step = .uploading
        errorMessage = nil
        do {
            _ = try await catalog.uploadCustomVoice(
                audio: url,
                language: language.rawValue,
                label: trimmedName,
                refText: refText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            // Success — clean up local WAV and dismiss back to picker.
            try? FileManager.default.removeItem(at: url)
            dismiss()
        } catch let error as VoiceCatalogError {
            errorMessage = describe(error)
            step = .ready
        } catch {
            errorMessage = "Upload-Fehler: \(error.localizedDescription)"
            step = .ready
        }
    }

    private func describe(_ error: VoiceCatalogError) -> String {
        switch error {
        case .notConfigured:
            return "Server-URL oder Bearer fehlt — siehe Einstellungen → Server."
        case .unauthorized:
            return "401 — Bearer stimmt nicht mit IOS_BEARER_TOKEN überein."
        case .audioTooLarge:
            return "Audio ist zu groß. Maximal 10 MB; kürzere Aufnahme wählen."
        case .audioFormat:
            return "Audio-Format wird nicht akzeptiert (erwartet: WAV)."
        case .voiceNotFound:
            return "Stimme nicht gefunden."
        case .serverError(let status, let detail):
            return "Server \(status): \(detail)"
        case .transport(let underlying):
            return "Netzwerk-Fehler: \(underlying.localizedDescription)"
        case .decodeFailed(let reason):
            return "Antwort konnte nicht gelesen werden: \(reason)"
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
