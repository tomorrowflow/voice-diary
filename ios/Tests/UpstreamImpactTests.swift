import Foundation
import Testing
@testable import VoiceDiary

// Impact lines from `/health` probe results (Mehr → Server, walkthrough
// start notice), the pending-upload summary and the Verlauf failed-segment
// explanation. Pure — no network, no views.

@Suite("UpstreamImpact")
struct UpstreamImpactTests {
    private let healthy: [String: String] = [
        "postgres": "ok", "qdrant": "ok", "whisper": "ok", "lightrag": "ok",
        "ollama": "ok", "msgraph": "ok", "voxtral": "ok",
    ]

    private func health(_ overrides: [String: String]) -> [String: String] {
        healthy.merging(overrides) { _, new in new }
    }

    @Test("a healthy server has no impact lines")
    func healthyHasNone() {
        #expect(UpstreamImpact.lines(health: healthy, language: .de).isEmpty)
    }

    @Test("skipped and fixture upstreams show no line")
    func skippedAndFixtureAreSilent() {
        let probes = health(["lightrag": "skipped", "msgraph": "fixture", "voxtral": "skipped"])
        #expect(UpstreamImpact.lines(health: probes, language: .de).isEmpty)
    }

    @Test("infrastructure probes are not upstreams of the contract")
    func infrastructureIsIgnored() {
        let probes = health(["postgres": "down", "qdrant": "down"])
        #expect(UpstreamImpact.lines(health: probes, language: .de).isEmpty)
    }

    @Test("each down upstream gets its PRD impact sentence, in a fixed order")
    func impactSentencesInOrder() {
        let probes = health([
            "voxtral": "down", "msgraph": "down", "ollama": "down", "whisper": "down",
        ])
        let lines = UpstreamImpact.lines(health: probes, language: .de)
        #expect(lines.map(\.upstream) == ["whisper", "ollama", "msgraph", "voxtral"])
        #expect(lines.map(\.name) == ["Whisper", "Ollama", "Microsoft Graph", "Voxtral"])
        #expect(lines.map(\.impact) == [
            "Aufnahmen bleiben auf dem Handy und werden später hochgeladen.",
            "Auswertung verzögert sich, deine Texte sind gespeichert.",
            "Kalender und Mail sind gerade nicht erreichbar.",
            "Server-Stimmen fallen auf Piper zurück.",
        ])
    }

    @Test("LightRAG shares the Ollama sentence")
    func lightragImpact() {
        let lines = UpstreamImpact.lines(health: health(["lightrag": "down"]), language: .en)
        #expect(lines.map(\.impact) == ["Analysis is delayed; your texts are saved."])
    }

    @Test("Graph not bootstrapped says it has to be fixed on the server")
    func notBootstrapped() {
        let lines = UpstreamImpact.lines(health: health(["msgraph": "not_bootstrapped"]), language: .de)
        #expect(lines.map(\.impact) == [
            "Kalender ist auf dem Server nicht eingerichtet. Das muss am Server erledigt werden.",
        ])
    }

    @Test("an unknown non-ok result from a newer server still gets the upstream's line")
    func unknownResultIsUnhealthy() {
        let lines = UpstreamImpact.lines(health: health(["whisper": "starting"]), language: .en)
        #expect(lines.map(\.impact) == ["Recordings stay on your phone and upload later."])
    }

    @Test("every impact line is non-empty in both languages")
    func bothLanguages() {
        let probes = health([
            "whisper": "down", "ollama": "down", "lightrag": "down", "msgraph": "not_bootstrapped",
            "voxtral": "down",
        ])
        for language in [OpenerLanguage.de, .en] {
            let lines = UpstreamImpact.lines(health: probes, language: language)
            #expect(lines.count == 5)
            #expect(lines.allSatisfy { !$0.impact.isEmpty })
        }
    }

    // MARK: - Start notice

    @Test("start notice is nil when nothing relevant is unhealthy")
    func noticeNilWhenHealthy() {
        #expect(UpstreamImpact.startNotice(health: healthy, includeVoxtral: true, language: .de) == nil)
    }

    @Test("start notice lists each distinct sentence once, one per line")
    func noticeDeduplicates() {
        let probes = health(["ollama": "down", "lightrag": "down", "msgraph": "down"])
        let notice = UpstreamImpact.startNotice(health: probes, includeVoxtral: false, language: .de)
        #expect(notice == """
            Auswertung verzögert sich, deine Texte sind gespeichert.
            Kalender und Mail sind gerade nicht erreichbar.
            """)
    }

    @Test("Voxtral only reaches the start notice when a server voice is selected")
    func noticeVoxtralNeedsSelectedVoice() {
        let probes = health(["voxtral": "down"])
        #expect(UpstreamImpact.startNotice(health: probes, includeVoxtral: false, language: .en) == nil)
        #expect(UpstreamImpact.startNotice(health: probes, includeVoxtral: true, language: .en)
                == "Server voices fall back to Piper.")
    }
}

@Suite("PendingUploadSummary")
struct PendingUploadSummaryTests {
    private func entry(
        _ id: String,
        code: String? = nil,
        permanentlyFailed: Bool = false
    ) -> SessionUploader.QueueEntry {
        .init(
            id: id,
            manifest: Manifest(session_id: id, date: "2026-04-27"),
            audio_file_paths: [:],
            attempts: 1,
            next_attempt_at: Date(timeIntervalSince1970: 1_800_000_000),
            permanentlyFailed: permanentlyFailed,
            last_failure_code: code
        )
    }

    @Test("an empty queue has no summary, so the indicator disappears")
    func emptyQueue() {
        #expect(PendingUploadSummary.make(from: []) == nil)
    }

    @Test("counts waiting sessions and takes the oldest failure code")
    func countAndCode() {
        let summary = PendingUploadSummary.make(from: [
            entry("a"),
            entry("b", code: "whisper_unavailable"),
            entry("c", code: "whisper_timeout"),
        ])
        #expect(summary == PendingUploadSummary(count: 3, lastFailureCode: "whisper_unavailable"))
    }

    @Test("permanently rejected entries are not waiting")
    func permanentEntriesSkipped() {
        #expect(PendingUploadSummary.make(from: [entry("a", code: "x", permanentlyFailed: true)]) == nil)
        let summary = PendingUploadSummary.make(from: [
            entry("a", code: "ollama_unavailable", permanentlyFailed: true),
            entry("b"),
        ])
        #expect(summary == PendingUploadSummary(count: 1, lastFailureCode: nil))
    }

    @Test("explanation follows the failure code in German and English")
    func explanation() throws {
        let summary = try #require(PendingUploadSummary.make(from: [entry("a", code: "whisper_unavailable")]))
        #expect(summary.explanation(language: .en)?.title == "Transcription isn’t available")
        #expect(summary.explanation(language: .de)?.impact
                == "Aufnahmen bleiben auf dem Handy und werden später hochgeladen.")
    }

    @Test("no explanation without a code or with an unrecognised one")
    func noExplanation() throws {
        let none = try #require(PendingUploadSummary.make(from: [entry("a")]))
        #expect(none.explanation(language: .de) == nil)
        let unknown = try #require(PendingUploadSummary.make(from: [entry("a", code: "something_new")]))
        #expect(unknown.explanation(language: .de) == nil)
    }
}

@Suite("Failed segment explanation")
struct FailedSegmentExplanationTests {
    @Test("a coded failure is explained in German and English")
    func coded() throws {
        let de = try #require(FailureCatalog.copy(forSegmentCode: "whisper_timeout", upstream: "whisper", language: .de))
        let en = try #require(FailureCatalog.copy(forSegmentCode: "whisper_timeout", upstream: "whisper", language: .en))
        #expect(en.title == "Transcription is taking too long")
        #expect(de.title != en.title)
    }

    @Test("without a code the segment keeps today's pill, even with an upstream")
    func uncoded() {
        #expect(FailureCatalog.copy(forSegmentCode: nil, upstream: nil, language: .de) == nil)
        #expect(FailureCatalog.copy(forSegmentCode: nil, upstream: "whisper", language: .de) == nil)
        #expect(FailureCatalog.copy(forSegmentCode: "", upstream: "whisper", language: .de) == nil)
    }

    @Test("an unknown code from a known upstream gets the generic failed copy")
    func unknownCode() throws {
        let copy = try #require(FailureCatalog.copy(forSegmentCode: "ollama_new_thing", upstream: "ollama", language: .en))
        #expect(copy.title == "Analysis failed")
    }

    @Test("an unknown code with no upstream has no copy")
    func unknownCodeNoUpstream() {
        #expect(FailureCatalog.copy(forSegmentCode: "something_new", upstream: nil, language: .en) == nil)
    }
}
