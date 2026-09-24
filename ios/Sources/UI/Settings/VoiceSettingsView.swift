import AVFoundation
import SwiftUI

// Per-language voice picker. Combines Apple Premium voices (filtered
// from `AVSpeechSynthesisVoice.speechVoices()`) and bundled Piper
// voices (`PiperTTS.voices`) into a single radio list per language.
//
// The selected row is the source of truth for both *which engine* runs
// (the registry switches on the `piper:` prefix) and *which voice
// within that engine* speaks. There is no separate engine picker — the
// caption under each row tells the user which engine they're on.
//
// Non-premium Apple voices (Enhanced / Standard / Compact) are
// intentionally hidden — they sound noticeably worse than both Premium
// and Piper. If the user wants them, they can re-enable them via the
// system Settings → Accessibility flow and we'll surface them again
// when they change tier.
//
// Preview taps speak a one-line German or English sample with the
// chosen voice using a dedicated `previewSynth` (Apple) or
// `PiperTTS.shared.speak(text, stem:)` (Piper) — kept separate from
// the walkthrough's continuation map so a tap never collides with an
// in-flight evening session.

@MainActor
public struct VoiceSettingsView: View {
    @State private var appleVoicesByLanguage: [String: [AVSpeechSynthesisVoice]] = [:]
    @State private var selectedIDByLanguage: [String: String?] = [:]
    @State private var previewing: String?
    @State private var mixedLanguageSpeech: Bool = WalkthroughSettingsStore.mixedLanguageSpeech
    @StateObject private var voiceCatalog = VoiceCatalogClient.shared
    @StateObject private var reachability = Reachability()
    // Dedicated synthesizer for Apple previews — kept separate from
    // AppleSpeechTTS.shared so a preview tap never collides with the
    // walkthrough's continuation map.
    @State private var previewSynth = AVSpeechSynthesizer()

    private static let supportedLanguages: [(code: String, label: String, sample: String)] = [
        ("de", "Deutsch",  "Hallo, ich bin deine Stimme für das Voice Diary."),
        ("en", "English",  "Hello, I'm your Voice Diary voice."),
    ]

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.color.bg.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                FlowHeader(title: "Voices")

                Form {
                    voxtralReachabilitySection

                    ForEach(Self.supportedLanguages, id: \.code) { lang in
                        let appleVoices = appleVoicesByLanguage[lang.code] ?? []
                        let piperVoices = PiperTTS.voices(for: lang.code)
                        let voxtralVoices = voiceCatalog.voices(for: lang.code)

                        Section {
                            ForEach(appleVoices, id: \.identifier) { voice in
                                appleRow(voice: voice, language: lang.code, sample: lang.sample)
                            }
                            ForEach(piperVoices, id: \.stem) { voice in
                                piperRow(voice: voice, language: lang.code)
                            }
                            ForEach(voxtralVoices, id: \.id) { voice in
                                voxtralRow(voice: voice, language: lang.code, sample: lang.sample)
                            }
                            if appleVoices.isEmpty && piperVoices.isEmpty && voxtralVoices.isEmpty {
                                Text("No voices available. Download a Premium voice in iOS Settings → Accessibility → Spoken Content → Voices, or connect your server in Server settings.")
                                    .font(Theme.font.caption)
                                    .foregroundStyle(Theme.color.text.subdued)
                            }
                        } header: {
                            Text(lang.label)
                                .font(Theme.font.subheadline)
                                .foregroundStyle(Theme.color.text.secondary)
                        }
                    }

                    Section {
                        Toggle(isOn: Binding(
                            get: { mixedLanguageSpeech },
                            set: { newValue in
                                mixedLanguageSpeech = newValue
                                WalkthroughSettingsStore.setMixedLanguageSpeech(newValue)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Detect language per event")
                                    .font(Theme.font.body)
                                Text("Events with English titles are read with the English voice; the surrounding German frame stays German.")
                                    .font(Theme.font.caption)
                                    .foregroundStyle(Theme.color.text.subdued)
                            }
                        }
                    } header: {
                        Text("Voice output")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    }

                    Section {
                        Text("Apple Premium voices need a one-time download in iOS Settings. Piper voices ship with the app and play fully on-device. Server voices stream from your own server — higher quality, but they need a connection.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadVoices() }
        // `.task` (not fire-and-forget Tasks in onAppear) so the network
        // refreshes are cancelled automatically when the user leaves.
        .task {
            await voiceCatalog.refresh()
            await reachability.refresh()
        }
    }

    // MARK: - Voxtral reachability section

    private var voxtralReachabilitySection: some View {
        Section {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: voxtralReachabilityIcon)
                    .foregroundStyle(voxtralReachabilityColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voxtralReachabilityLabel)
                        .font(Theme.font.body)
                        .foregroundStyle(Theme.color.text.primary)
                    Text(voxtralReachabilityDetail)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                }
                Spacer()
                Button {
                    Task {
                        await reachability.refresh()
                        await voiceCatalog.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Theme.color.text.link)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Re-check server connection"))
            }
            if let catalogError = voiceCatalog.lastError {
                Text("Server voices could not be loaded: \(catalogError)")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
                Button {
                    Task { await voiceCatalog.refresh() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.color.text.link)
                .disabled(voiceCatalog.isLoading)
            }
        } header: {
            Text("Server voices")
                .font(Theme.font.subheadline)
                .foregroundStyle(Theme.color.text.secondary)
        }
    }

    private var voxtralUpstreamValue: String? {
        switch reachability.status {
        case .ok(let upstream), .degraded(let upstream):
            return upstream["voxtral"]
        default:
            return nil
        }
    }

    private var voxtralReachabilityIcon: String {
        switch voxtralUpstreamValue {
        case "ok":      return "checkmark.circle.fill"
        case "down":    return "exclamationmark.triangle.fill"
        case "skipped": return "minus.circle"
        default:        return "questionmark.circle"
        }
    }

    private var voxtralReachabilityColor: Color {
        switch voxtralUpstreamValue {
        case "ok":      return Theme.color.status.success
        case "down":    return Theme.color.status.destructive
        case "skipped": return Theme.color.text.subdued
        default:        return Theme.color.text.subdued
        }
    }

    private var voxtralReachabilityLabel: String {
        switch voxtralUpstreamValue {
        case "ok":      return String(localized: "Connected")
        case "down":    return String(localized: "Unreachable")
        case "skipped": return String(localized: "Not configured")
        default:
            switch reachability.status {
            case .authInvalid: return String(localized: "Bearer invalid")
            case .down:        return String(localized: "Server unreachable")
            default:           return String(localized: "Status unknown")
            }
        }
    }

    private var voxtralReachabilityDetail: String {
        switch voxtralUpstreamValue {
        case "ok":
            return String(localized: "Server voices are available. If the connection drops, playback falls back to your Piper or Apple voice automatically.")
        case "down":
            return String(localized: "The server’s voice service is not responding. Server voices fall back to your Piper or Apple voice; the walkthrough keeps running.")
        case "skipped":
            return String(localized: "No server voices are configured on the server.")
        default:
            return String(localized: "The connection is checked when you open Settings. Tap ↻ to re-check.")
        }
    }

    // MARK: - Rows

    private func appleRow(voice: AVSpeechSynthesisVoice, language: String, sample: String) -> some View {
        let isSelected = (selectedIDByLanguage[language] ?? nil) == voice.identifier
        let isPreviewing = previewing == voice.identifier
        return HStack(spacing: Theme.spacing.sm) {
            Button {
                VoicePreferences.setSelectedVoiceID(voice.identifier, for: language)
                selectedIDByLanguage[language] = voice.identifier
            } label: {
                HStack(spacing: Theme.spacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.color.text.link : Theme.color.text.subdued)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name)
                            .font(Theme.font.body)
                            .foregroundStyle(Theme.color.text.primary)
                        Text("Apple Premium · System (\(voice.language))")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await previewApple(voice: voice, sample: sample) }
            } label: {
                if isPreviewing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.color.text.link)
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreviewing)
            .accessibilityLabel(Text("Preview \(voice.name)"))
        }
    }

    private func piperRow(voice: PiperTTS.PiperVoice, language: String) -> some View {
        let available = PiperTTS.assets(forStem: voice.stem) != nil
        let isSelected = (selectedIDByLanguage[language] ?? nil) == voice.voiceID
        let isPreviewing = previewing == voice.voiceID
        return HStack(spacing: Theme.spacing.sm) {
            Button {
                guard available else { return }
                VoicePreferences.setSelectedVoiceID(voice.voiceID, for: language)
                selectedIDByLanguage[language] = voice.voiceID
            } label: {
                HStack(spacing: Theme.spacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.color.text.link : Theme.color.text.subdued)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.label)
                            .font(Theme.font.body)
                            .foregroundStyle(available ? Theme.color.text.primary : Theme.color.text.subdued)
                        Text(available
                             ? voice.accent
                             : String(localized: "\(voice.accent) — models not installed"))
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!available)

            Button {
                Task { await previewPiper(voice: voice) }
            } label: {
                if isPreviewing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(available ? Theme.color.text.link : Theme.color.text.subdued)
                }
            }
            .buttonStyle(.plain)
            .disabled(!available || isPreviewing)
            .accessibilityLabel(Text("Preview \(voice.label)"))
        }
    }

    private func voxtralRow(voice: VoxtralVoice, language: String, sample: String) -> some View {
        let isSelected = (selectedIDByLanguage[language] ?? nil) == voice.voiceID
        let isPreviewing = previewing == voice.voiceID
        return HStack(spacing: Theme.spacing.sm) {
            Button {
                VoicePreferences.setSelectedVoiceID(voice.voiceID, for: language)
                selectedIDByLanguage[language] = voice.voiceID
            } label: {
                HStack(spacing: Theme.spacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.color.text.link : Theme.color.text.subdued)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.label)
                            .font(Theme.font.body)
                            .foregroundStyle(Theme.color.text.primary)
                        Text("Server — \(voice.description)")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await previewVoxtral(voice: voice, language: language, sample: sample) }
            } label: {
                if isPreviewing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.color.text.link)
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreviewing)
            .accessibilityLabel(Text("Preview \(voice.label)"))
        }
    }

    // MARK: - Loading + preview

    private func loadVoices() {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        var grouped: [String: [AVSpeechSynthesisVoice]] = [:]
        for lang in Self.supportedLanguages.map(\.code) {
            // Premium-only — Enhanced and Standard tiers are intentionally
            // hidden because they sound noticeably worse than both Premium
            // and Piper, and the long unfiltered list overwhelms the picker.
            let candidates = installed.filter {
                $0.language.hasPrefix(lang) && $0.quality == .premium
            }
            grouped[lang] = candidates.sorted { $0.name < $1.name }
            selectedIDByLanguage[lang] = VoicePreferences.selectedVoiceID(for: lang)
        }
        appleVoicesByLanguage = grouped
    }

    private func previewApple(voice: AVSpeechSynthesisVoice, sample: String) async {
        previewing = voice.identifier
        defer { previewing = nil }

        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.preUtteranceDelay = 0.05
        previewSynth.speak(utterance)
        // Hold the spinner roughly as long as iOS will speak — the
        // synth has its own delegate; we just need a simple debounce.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
    }

    private func previewPiper(voice: PiperTTS.PiperVoice) async {
        previewing = voice.voiceID
        defer { previewing = nil }
        // Pass the explicit stem so the preview demonstrates *this* row's
        // voice, regardless of what the user has currently saved.
        await PiperTTS.shared.speak(voice.sample, stem: voice.stem, language: voice.language)
    }

    private func previewVoxtral(voice: VoxtralVoice, language: String, sample: String) async {
        previewing = voice.voiceID
        defer { previewing = nil }
        // Pass the bare voice id so the preview demonstrates *this* row's
        // voice, regardless of what the user has currently saved.
        await VoxtralTTS.shared.speak(sample, voice: voice.id, language: language)
    }
}
