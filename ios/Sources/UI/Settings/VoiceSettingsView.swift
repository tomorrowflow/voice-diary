import AVFoundation
import SwiftUI

// Per-language voice picker. Reads installed voices from
// `AVSpeechSynthesisVoice.speechVoices()` at appear time, groups them by
// language (de / en), surfaces the quality tier (Premium/Enhanced/Standard)
// and lets the user lock in a specific voice — or "Auto" to fall back to
// the AppleSpeechTTS auto-selection (Premium > Enhanced > default).
//
// Preview taps speak a one-line German or English sample with the chosen
// voice (using `AppleSpeechTTS.shared` so volume + audio session match
// the walkthrough). The selection takes effect immediately — no rebuild
// required.

@MainActor
public struct VoiceSettingsView: View {
    @State private var voicesByLanguage: [String: [AVSpeechSynthesisVoice]] = [:]
    @State private var overrideByLanguage: [String: String?] = [:]
    @State private var previewing: String?
    // Dedicated synthesizer for previews — kept separate from
    // AppleSpeechTTS.shared so a preview tap never collides with the
    // walkthrough's continuation map.
    @State private var previewSynth = AVSpeechSynthesizer()

    private static let supportedLanguages: [(code: String, label: String, sample: String)] = [
        ("de", "Deutsch",  "Hallo, ich bin deine Stimme für das Voice Diary."),
        ("en", "English",  "Hello, I'm your Voice Diary voice."),
    ]

    public init() {}

    public var body: some View {
        Form {
            ForEach(Self.supportedLanguages, id: \.code) { lang in
                Section {
                    autoRow(language: lang.code)
                    ForEach(voicesByLanguage[lang.code] ?? [], id: \.identifier) { voice in
                        voiceRow(voice: voice, language: lang.code, sample: lang.sample)
                    }
                    if (voicesByLanguage[lang.code] ?? []).isEmpty {
                        Text("Keine Stimmen installiert. iOS-Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen.")
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
                Text("Premium-Stimmen müssen einmalig in den iOS-Einstellungen geladen werden. Voice Diary spielt sie sofort ab — kein App-Neustart nötig.")
                    .font(Theme.font.caption)
                    .foregroundStyle(Theme.color.text.subdued)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.color.bg.surface.ignoresSafeArea())
        .navigationTitle("Stimmen")
        .onAppear { loadVoices() }
    }

    // MARK: - Rows

    private func autoRow(language: String) -> some View {
        let isSelected = (overrideByLanguage[language] ?? nil) == nil
        return Button {
            VoicePreferences.setSelectedVoiceID(nil, for: language)
            overrideByLanguage[language] = nil
        } label: {
            HStack(spacing: Theme.spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.color.text.link : Theme.color.text.subdued)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatisch")
                        .font(Theme.font.body)
                        .foregroundStyle(Theme.color.text.primary)
                    Text("Beste verfügbare Premium-Stimme")
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.color.text.subdued)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func voiceRow(voice: AVSpeechSynthesisVoice, language: String, sample: String) -> some View {
        let isSelected = (overrideByLanguage[language] ?? nil) == voice.identifier
        let isPreviewing = previewing == voice.identifier
        return HStack(spacing: Theme.spacing.sm) {
            Button {
                VoicePreferences.setSelectedVoiceID(voice.identifier, for: language)
                overrideByLanguage[language] = voice.identifier
            } label: {
                HStack(spacing: Theme.spacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.color.text.link : Theme.color.text.subdued)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.spacing.xs) {
                            Text(voice.name)
                                .font(Theme.font.body)
                                .foregroundStyle(Theme.color.text.primary)
                            QualityBadge(quality: voice.quality)
                        }
                        Text(voice.language)
                            .font(Theme.font.monoCaption)
                            .foregroundStyle(Theme.color.text.subdued)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await preview(voice: voice, sample: sample) }
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

    // MARK: - Loading + preview

    private func loadVoices() {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        var grouped: [String: [AVSpeechSynthesisVoice]] = [:]
        for lang in Self.supportedLanguages.map(\.code) {
            let prefix = lang
            let candidates = installed.filter { $0.language.hasPrefix(prefix) }
            // Sort: Premium first, then Enhanced, then default; tie-break
            // by name for stable ordering.
            grouped[lang] = candidates.sorted { lhs, rhs in
                let lq = score(lhs.quality), rq = score(rhs.quality)
                if lq != rq { return lq > rq }
                return lhs.name < rhs.name
            }
            overrideByLanguage[lang] = VoicePreferences.selectedVoiceID(for: lang)
        }
        voicesByLanguage = grouped
    }

    private func preview(voice: AVSpeechSynthesisVoice, sample: String) async {
        previewing = voice.identifier
        defer { previewing = nil }

        // Speak the sample with the picked voice — use the shared
        // synth via a one-off utterance configured directly so the
        // preview ignores any persisted preference and demonstrates
        // the voice the user is *about* to choose.
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.preUtteranceDelay = 0.05
        previewSynth.speak(utterance)
        // Hold the spinner roughly as long as iOS will speak — the
        // synth has its own delegate; we just need a simple debounce.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
    }

    private func score(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:  return 3
        case .enhanced: return 2
        default:        return 1
        }
    }
}

private struct QualityBadge: View {
    let quality: AVSpeechSynthesisVoiceQuality

    var body: some View {
        Text(label)
            .font(Theme.font.caption2.weight(.medium))
            .foregroundStyle(textColor)
            .padding(.horizontal, Theme.spacing.xs)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(bgColor)
            )
    }

    private var label: String {
        switch quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Standard"
        }
    }

    private var textColor: Color {
        switch quality {
        case .premium:  return Theme.color.text.link
        case .enhanced: return Theme.color.status.success
        default:        return Theme.color.text.subdued
        }
    }

    private var bgColor: Color {
        switch quality {
        case .premium:  return Theme.color.text.link.opacity(0.10)
        case .enhanced: return Theme.color.status.success.opacity(0.10)
        default:        return Theme.color.bg.containerInset
        }
    }
}
