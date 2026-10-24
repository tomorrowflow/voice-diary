import Foundation
import Testing
@testable import VoiceDiary

// FailureCatalog maps the failure contract's (code, upstream) to DE/EN
// copy; ConnectionDiagnosis consults it before its status-based cases.

@Suite("FailureCatalog")
struct FailureCatalogTests {
    private func failure(_ code: String?, _ upstream: String?) -> UpstreamFailure {
        UpstreamFailure(code: code, upstream: upstream, retryable: true)
    }

    private let allCodes: [(code: String, upstream: String)] = [
        ("whisper_unavailable", "whisper"), ("whisper_timeout", "whisper"),
        ("whisper_engine_error", "whisper"),
        ("ollama_unavailable", "ollama"), ("ollama_timeout", "ollama"),
        ("ollama_engine_error", "ollama"),
        ("lightrag_unavailable", "lightrag"), ("lightrag_timeout", "lightrag"),
        ("lightrag_engine_error", "lightrag"),
        ("msgraph_not_bootstrapped", "msgraph"), ("msgraph_rate_limited", "msgraph"),
        ("msgraph_unavailable", "msgraph"), ("msgraph_engine_error", "msgraph"),
        ("voxtral_unavailable", "voxtral"), ("voxtral_timeout", "voxtral"),
        ("voxtral_engine_error", "voxtral"), ("unknown_voice", "voxtral"),
        ("blindfold_unavailable", "blindfold"), ("blindfold_timeout", "blindfold"),
        ("blindfold_engine_error", "blindfold"),
    ]

    @Test("every documented code has non-empty, distinct DE and EN copy")
    func everyCodeHasCopy() throws {
        for (code, upstream) in allCodes {
            let en = try #require(FailureCatalog.copy(for: failure(code, upstream), language: .en), "\(code) en")
            let de = try #require(FailureCatalog.copy(for: failure(code, upstream), language: .de), "\(code) de")
            for text in [en.title, en.hint, en.impact, de.title, de.hint, de.impact] {
                #expect(!text.isEmpty, "\(code)")
            }
            // A German value that equals the English key means the catalog
            // entry is missing its translation.
            #expect(de.title != en.title, "\(code) title untranslated")
            #expect(de.hint != en.hint, "\(code) hint untranslated")
            #expect(de.impact != en.impact, "\(code) impact untranslated")
        }
    }

    @Test("impact sentences follow the PRD copy")
    func impactSentences() throws {
        func impact(_ code: String, _ upstream: String, _ lang: OpenerLanguage) throws -> String {
            try #require(FailureCatalog.copy(for: failure(code, upstream), language: lang)).impact
        }
        #expect(try impact("whisper_unavailable", "whisper", .de)
                == "Aufnahmen bleiben auf dem Handy und werden später hochgeladen.")
        #expect(try impact("ollama_timeout", "ollama", .de)
                == "Auswertung verzögert sich, deine Texte sind gespeichert.")
        #expect(try impact("lightrag_engine_error", "lightrag", .de)
                == "Auswertung verzögert sich, deine Texte sind gespeichert.")
        #expect(try impact("msgraph_unavailable", "msgraph", .de)
                == "Kalender und Mail sind gerade nicht erreichbar.")
        #expect(try impact("msgraph_not_bootstrapped", "msgraph", .de)
                == "Kalender ist auf dem Server nicht eingerichtet. Das muss am Server erledigt werden.")
        #expect(try impact("voxtral_unavailable", "voxtral", .de)
                == "Server-Stimmen fallen auf Piper zurück.")
        #expect(try impact("whisper_unavailable", "whisper", .en)
                == "Recordings stay on your phone and upload later.")
    }

    @Test("titles name the failing upstream and condition")
    func titles() throws {
        func title(_ code: String, _ upstream: String, _ lang: OpenerLanguage) throws -> String {
            try #require(FailureCatalog.copy(for: failure(code, upstream), language: lang)).title
        }
        #expect(try title("whisper_unavailable", "whisper", .de) == "Transkription nicht verfügbar")
        #expect(try title("whisper_unavailable", "whisper", .en) == "Transcription isn’t available")
        #expect(try title("msgraph_rate_limited", "msgraph", .en) == "Calendar and mail are busy")
        #expect(try title("msgraph_not_bootstrapped", "msgraph", .de) == "Kalender und Mail sind nicht eingerichtet")
    }

    // (code, upstream, EN title, DE title)
    private let titleTable: [(String, String, String, String)] = [
        ("whisper_unavailable", "whisper", "Transcription isn’t available", "Transkription nicht verfügbar"),
        ("whisper_timeout", "whisper", "Transcription is taking too long", "Transkription dauert zu lange"),
        ("whisper_engine_error", "whisper", "Transcription failed", "Transkription fehlgeschlagen"),
        ("ollama_unavailable", "ollama", "Analysis isn’t available", "Auswertung nicht verfügbar"),
        ("ollama_timeout", "ollama", "Analysis is taking too long", "Auswertung dauert zu lange"),
        ("ollama_engine_error", "ollama", "Analysis failed", "Auswertung fehlgeschlagen"),
        ("lightrag_unavailable", "lightrag", "Diary memory isn’t available", "Tagebuch-Gedächtnis nicht verfügbar"),
        ("lightrag_timeout", "lightrag", "Diary memory is taking too long", "Tagebuch-Gedächtnis antwortet zu langsam"),
        ("lightrag_engine_error", "lightrag", "Diary memory failed", "Tagebuch-Gedächtnis fehlgeschlagen"),
        ("msgraph_unavailable", "msgraph", "Calendar and mail aren’t available", "Kalender und Mail nicht erreichbar"),
        ("msgraph_engine_error", "msgraph", "Calendar and mail failed", "Kalender und Mail fehlgeschlagen"),
        ("msgraph_rate_limited", "msgraph", "Calendar and mail are busy", "Kalender und Mail sind gerade ausgelastet"),
        ("msgraph_not_bootstrapped", "msgraph", "Calendar and mail aren’t set up",
         "Kalender und Mail sind nicht eingerichtet"),
        ("voxtral_unavailable", "voxtral", "Server voice isn’t available", "Server-Stimme nicht verfügbar"),
        ("voxtral_timeout", "voxtral", "Server voice is taking too long", "Server-Stimme antwortet zu langsam"),
        ("voxtral_engine_error", "voxtral", "Server voice failed", "Server-Stimme fehlgeschlagen"),
        ("unknown_voice", "voxtral", "Server voice not found", "Server-Stimme nicht gefunden"),
        ("blindfold_unavailable", "blindfold", "Private analysis isn’t available",
         "Geschützte Auswertung nicht verfügbar"),
        ("blindfold_timeout", "blindfold", "Private analysis is taking too long",
         "Geschützte Auswertung dauert zu lange"),
        ("blindfold_engine_error", "blindfold", "Private analysis failed",
         "Geschützte Auswertung fehlgeschlagen"),
    ]

    @Test("every title matches the documented DE and EN copy")
    func exactTitles() throws {
        for (code, upstream, en, de) in titleTable {
            #expect(try #require(FailureCatalog.copy(for: failure(code, upstream), language: .en)).title == en)
            #expect(try #require(FailureCatalog.copy(for: failure(code, upstream), language: .de)).title == de)
        }
    }

    // (code, upstream, EN hint, DE hint)
    private let hintTable: [(String, String, String, String)] = [
        ("whisper_unavailable", "whisper", "This is usually temporary. Try again in a moment.",
         "Das ist meist vorübergehend. Versuche es gleich noch einmal."),
        ("ollama_timeout", "ollama", "This is usually temporary. Try again in a moment.",
         "Das ist meist vorübergehend. Versuche es gleich noch einmal."),
        ("lightrag_engine_error", "lightrag",
         "The service answered with an error. Try again in a moment; if it keeps happening, check the server logs.",
         "Der Dienst hat mit einem Fehler geantwortet. Versuche es gleich noch einmal; wenn es bleibt, schau in die Server-Logs."),
        ("blindfold_unavailable", "blindfold", "This is usually temporary. Try again in a moment.",
         "Das ist meist vorübergehend. Versuche es gleich noch einmal."),
        ("blindfold_timeout", "blindfold", "This is usually temporary. Try again in a moment.",
         "Das ist meist vorübergehend. Versuche es gleich noch einmal."),
        ("blindfold_engine_error", "blindfold",
         "The service answered with an error. Try again in a moment; if it keeps happening, check the server logs.",
         "Der Dienst hat mit einem Fehler geantwortet. Versuche es gleich noch einmal; wenn es bleibt, schau in die Server-Logs."),
        ("msgraph_rate_limited", "msgraph", "Microsoft is asking for a short pause. Try again in a moment.",
         "Microsoft bittet um eine kurze Pause. Versuche es gleich noch einmal."),
        ("msgraph_not_bootstrapped", "msgraph",
         "Microsoft sign-in has to be completed on the server. This can’t be fixed on the phone.",
         "Die Microsoft-Anmeldung muss am Server abgeschlossen werden. Das lässt sich nicht am Handy beheben."),
        ("unknown_voice", "voxtral", "Choose a different voice in the voice settings.",
         "Wähle in den Stimmen-Einstellungen eine andere Stimme."),
    ]

    @Test("every hint matches the documented DE and EN copy")
    func exactHints() throws {
        for (code, upstream, en, de) in hintTable {
            #expect(try #require(FailureCatalog.copy(for: failure(code, upstream), language: .en)).hint == en)
            #expect(try #require(FailureCatalog.copy(for: failure(code, upstream), language: .de)).hint == de)
        }
    }

    @Test("English impact sentences")
    func englishImpacts() throws {
        func impact(_ code: String, _ upstream: String) throws -> String {
            try #require(FailureCatalog.copy(for: failure(code, upstream), language: .en)).impact
        }
        #expect(try impact("ollama_unavailable", "ollama") == "Analysis is delayed; your texts are saved.")
        #expect(try impact("msgraph_engine_error", "msgraph") == "Calendar and mail aren’t reachable right now.")
        #expect(try impact("msgraph_not_bootstrapped", "msgraph")
                == "Calendar isn’t set up on the server. This has to be fixed on the server.")
        #expect(try impact("voxtral_timeout", "voxtral") == "Server voices fall back to Piper.")
    }

    @Test("every Blindfold code has the Ollama impact line in both languages",
          arguments: ["blindfold_unavailable", "blindfold_timeout", "blindfold_engine_error", "blindfold_something_new"])
    func blindfoldImpact(code: String) throws {
        let en = try #require(FailureCatalog.copy(for: failure(code, "blindfold"), language: .en))
        let de = try #require(FailureCatalog.copy(for: failure(code, "blindfold"), language: .de))
        #expect(en.impact == "Analysis is delayed; your texts are saved.")
        #expect(de.impact == "Auswertung verzögert sich, deine Texte sind gespeichert.")
        #expect(en.summary == "\(en.hint) \(en.impact)")
    }

    @Test("an unknown Blindfold code gets the generic private-analysis failed copy")
    func unknownBlindfoldCode() throws {
        let en = try #require(FailureCatalog.copy(for: failure("blindfold_something_new", "blindfold"), language: .en))
        let de = try #require(FailureCatalog.copy(for: failure("blindfold_something_new", "blindfold"), language: .de))
        #expect(en.title == "Private analysis failed")
        #expect(de.title == "Geschützte Auswertung fehlgeschlagen")
        // The upstream alone is enough, without any code.
        #expect(FailureCatalog.copy(for: UpstreamFailure(upstream: "blindfold"), language: .en)?.title
                == "Private analysis failed")
    }

    @Test("a Blindfold code never reads as Ollama's Analysis copy")
    func blindfoldIsNotOllama() throws {
        let blindfold = try #require(FailureCatalog.copy(for: failure("blindfold_timeout", "blindfold"), language: .en))
        let ollama = try #require(FailureCatalog.copy(for: failure("ollama_timeout", "ollama"), language: .en))
        #expect(blindfold.title != ollama.title)
    }

    @Test("a failed Verlauf segment with a Blindfold code gets its copy")
    func blindfoldSegment() throws {
        let copy = try #require(FailureCatalog.copy(
            forSegmentCode: "blindfold_unavailable", upstream: "blindfold", language: .de))
        #expect(copy.title == "Geschützte Auswertung nicht verfügbar")
    }

    @Test("ConnectionDiagnosis explains a Blindfold failure in either language")
    func blindfoldDiagnosis() {
        let error = ServerClientError.http(
            status: 503, detail: "blindfold_unavailable: connection refused",
            failure: failure("blindfold_unavailable", "blindfold")
        )
        let en = ConnectionDiagnosis.classify(error, language: .en)
        #expect(en.kind == .upstreamFailure)
        #expect(en.title == "Private analysis isn’t available")
        #expect(en.hint.contains("Analysis is delayed; your texts are saved."))
        let de = ConnectionDiagnosis.classify(error, language: .de)
        #expect(de.title == "Geschützte Auswertung nicht verfügbar")
        #expect(de.hint.contains("Auswertung verzögert sich, deine Texte sind gespeichert."))
    }

    @Test("not-bootstrapped Graph has its own spoken line in both languages")
    func notBootstrappedSpoken() {
        let f = failure("msgraph_not_bootstrapped", "msgraph")
        #expect(FailureCatalog.spokenEnrichmentLine(for: f, language: .de)
                == "Kalender und Mail sind auf dem Server nicht eingerichtet. Anreicherung übersprungen.")
        #expect(FailureCatalog.spokenEnrichmentLine(for: f, language: .en)
                == "Calendar and mail aren’t set up on the server. Enrichment skipped.")
    }

    @Test("language nil resolves through the app's current language and is never empty")
    func currentLanguage() throws {
        let copy = try #require(FailureCatalog.copy(for: failure("ollama_unavailable", "ollama")))
        let en = try #require(FailureCatalog.copy(for: failure("ollama_unavailable", "ollama"), language: .en))
        let de = try #require(FailureCatalog.copy(for: failure("ollama_unavailable", "ollama"), language: .de))
        #expect([en.title, de.title].contains(copy.title))
    }

    @Test("a missing upstream is derived from the code")
    func codeWithoutUpstream() throws {
        let copy = try #require(FailureCatalog.copy(for: UpstreamFailure(code: "ollama_timeout"), language: .en))
        #expect(copy.title == "Analysis is taking too long")
    }

    @Test("an unknown code from a known upstream still gets that upstream's copy")
    func unknownCodeKnownUpstream() throws {
        let copy = try #require(FailureCatalog.copy(for: failure("ollama_something_new", "ollama"), language: .en))
        #expect(copy.title == "Analysis failed")
    }

    @Test("no code and no known upstream gives no copy")
    func noCopy() {
        #expect(FailureCatalog.copy(for: UpstreamFailure()) == nil)
        #expect(FailureCatalog.copy(for: UpstreamFailure(retryable: true, retryAfter: 3)) == nil)
        #expect(FailureCatalog.copy(for: failure("something_new", "elsewhere")) == nil)
        #expect(FailureCatalog.copy(for: failure("session_busy", nil)) == nil)
    }

    // MARK: - ConnectionDiagnosis

    @Test("ConnectionDiagnosis explains a coded failure first, in either language")
    func diagnosisCoded() {
        let error = ServerClientError.http(
            status: 503, detail: "whisper_unavailable: connection refused",
            failure: failure("whisper_unavailable", "whisper")
        )
        let en = ConnectionDiagnosis.classify(error, language: .en)
        #expect(en.kind == .upstreamFailure)
        #expect(en.title == "Transcription isn’t available")
        #expect(en.hint.contains("Recordings stay on your phone and upload later."))
        #expect(en.detail == "HTTP 503: whisper_unavailable: connection refused")
        let de = ConnectionDiagnosis.classify(error, language: .de)
        #expect(de.title == "Transkription nicht verfügbar")
        #expect(de.hint.contains("Aufnahmen bleiben auf dem Handy"))
    }

    @Test("ConnectionDiagnosis keeps the status-based cases without a code",
          arguments: [(500, ConnectionDiagnosis.Kind.serverError), (503, .serverError),
                      (401, .unauthorised), (404, .clientError), (429, .clientError)])
    func diagnosisFallback(status: Int, kind: ConnectionDiagnosis.Kind) {
        let plain = ServerClientError.http(status: status, detail: "boom")
        let diagnosis = ConnectionDiagnosis.classify(plain, language: .de)
        #expect(diagnosis.kind == kind)
        #expect(!diagnosis.title.isEmpty)
        #expect(!diagnosis.hint.isEmpty)
        // Fields present but no recognised code/upstream: same fallback.
        let partial = ServerClientError.http(
            status: status, detail: "boom", failure: UpstreamFailure(retryable: true, retryAfter: 2)
        )
        #expect(ConnectionDiagnosis.classify(partial, language: .de) == diagnosis)
    }

    @Test("a 5xx old-server body keeps today's German status message")
    func oldServerMessage() {
        let diagnosis = ConnectionDiagnosis.classify(
            ServerClientError.http(status: 502, detail: "rate_limited: backoff_exhausted"),
            language: .de
        )
        #expect(diagnosis.title == "Server-Fehler")
    }
}
