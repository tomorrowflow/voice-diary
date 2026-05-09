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
                FlowHeader(title: "Stimmen")

                Form {
                    ForEach(Self.supportedLanguages, id: \.code) { lang in
                        let appleVoices = appleVoicesByLanguage[lang.code] ?? []
                        let piperVoices = PiperTTS.voices(for: lang.code)

                        Section {
                            ForEach(appleVoices, id: \.identifier) { voice in
                                appleRow(voice: voice, language: lang.code, sample: lang.sample)
                            }
                            ForEach(piperVoices, id: \.stem) { voice in
                                piperRow(voice: voice, language: lang.code)
                            }
                            if appleVoices.isEmpty && piperVoices.isEmpty {
                                Text("Keine Stimmen verfügbar. Premium-Stimme über iOS-Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen laden, oder `ios/scripts/fetch_piper_voices.sh` ausführen.")
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
                                Text("Sprache pro Termin erkennen")
                                    .font(Theme.font.body)
                                Text("Englisch betitelte Termine werden mit der englischen Stimme gelesen, der deutsche Rahmen bleibt deutsch.")
                                    .font(Theme.font.caption)
                                    .foregroundStyle(Theme.color.text.subdued)
                            }
                        }
                    } header: {
                        Text("Sprachausgabe")
                            .font(Theme.font.subheadline)
                            .foregroundStyle(Theme.color.text.secondary)
                    }

                    Section {
                        Text("Apple-Premium-Stimmen müssen einmalig in den iOS-Einstellungen geladen werden. Piper-Stimmen werden mit der App ausgeliefert (≈ 110 MB pro Stimme). Beide Engines spielen direkt auf dem Gerät — keine Cloud.")
                            .font(Theme.font.caption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadVoices() }
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
                             : "\(voice.accent) — Modelle nicht installiert")
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
}
