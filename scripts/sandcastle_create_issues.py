#!/usr/bin/env python3
"""Create GitHub issues from docs/REVIEW-2026-07-04.md findings for Sandcastle.

This file IS the editable manifest: the `F` list below is the source of truth for what
gets filed. After a `/grill-me` session, edit `F` (drop/merge/split/re-track findings) to
match the decisions, then run.

Idempotent: skips any finding whose [ID] already appears in an existing issue title.
Run:  python3 scripts/sandcastle_create_issues.py            # create
      python3 scripts/sandcastle_create_issues.py --dry-run  # print what would be created

See docs/SANDCASTLE-ISSUE-PLAN.md for the plan + the open decisions to resolve first.
"""
import subprocess
import sys

DRY = "--dry-run" in sys.argv

# finding, track, priority(high|None), area, severity, strength, title, files, problem, solution
F = [
    # ---- iOS architecture ----
    # DROPPED in grill 2026-07-04: IOS-A1 (umbrella, slices A6/A7/A8 stand alone),
    # IOS-A2 (merged into UX-1), IOS-A5, IOS-A9, IOS-A10, IOS-A15 (low payoff for a
    # single-user tool), IOS-A11 (bug claim false — fallback IS wired in VoxtralTTS;
    # see DOC-7).
    ("IOS-A3", "ios", None, "iOS architecture", "—", "Strong",
     "Stream multipart upload body to a temp file instead of RAM",
     "ios/Sources/Backend/ServerClient.swift:287-328 (makeMultipartBody), called :245",
     "Every audio file is appended into one growing Data — tens of MB resident on the code path most likely to run backgrounded and memory-pressured. The uploadSession seam is clean and deep, so the fix is local.",
     "Stream body to a temp file + session.upload(for:fromFile:)."),
    ("IOS-A4", "ios", None, "iOS architecture", "—", "Strong",
     "Upload queue must not drop the whole session when one segment file is missing",
     "ios/Sources/Backend/SessionUploader.swift:115-129 (purgeOrphans), :144-153 (flush does the same)",
     "Any single missing audio file discards an otherwise-complete multi-segment session; callers have no way to upload survivors. Recovery policy belongs behind the queue interface.",
     "Drop only the missing file + prune its manifest segment, upload the remainder, mark entry partial."),
    ("IOS-A6", "ios", None, "iOS architecture", "—", "Strong",
     "Extract OpenerPrefetcher from the coordinator",
     "ios/Sources/Dialog/WalkthroughCoordinator.swift:4022-4433 + 4 cache dictionaries",
     "~400 lines of genuinely deep behaviour (concurrent-FM dedup, cache-before-clear ordering, consume-once semantics) inline in the coordinator. Subtle ordering invariants deserve their own tested module.",
     "Extract OpenerPrefetcher actor: prefetch(segmentID:spans:), consume(segmentID:) -> Prefetched?, cancelAll()."),
    ("IOS-A7", "ios", None, "iOS architecture", "—", "Strong",
     "Extract PickupResolver from the coordinator",
     "ios/Sources/Dialog/WalkthroughCoordinator.swift:508-~700",
     "PauseMarker (de)serialization, a 50-line switch state re-encoding every WalkthroughState case, and score-based inferPickupPoint — pure logic over segment arrays, ideal unit-test target, currently untestable without the whole coordinator.",
     "Extract PickupResolver."),
    ("IOS-A8", "ios", None, "iOS architecture", "—", "Strong",
     "Extract TranscriptExcerpt + TodoConfirmationFlow from god file and view",
     "ios/Sources/Dialog/WalkthroughCoordinator.swift:3145-3601; ios/Sources/UI/Walkthrough/WalkthroughView.swift:1401-1560 (TodoConfirmationCard)",
     "~120 lines of pure text algorithms (sentence split, token overlap, excerpt windowing with center-2/end-5 clamps) live inside a SwiftUI View — exactly where off-by-one excerpt bugs hide, untestable without instantiating the view.",
     "Pure TranscriptExcerpt module (transcript + needle -> text + highlight range) + TodoConfirmationFlow for the coordinator half."),
    ("IOS-A12", "ios", None, "iOS architecture", "—", "Worth exploring",
     "Extract SessionMutations + HistoryGrouping from VerlaufView",
     "ios/Sources/UI/Verlauf/VerlaufView.swift (rewriteVoiceNoteMetadata:535, deleteSegment:504, share-merge :949-1035, status polling :582)",
     "A SwiftUI view rewrites metadata.json, deletes segments, merges audio, polls server status, and kicks the upload queue — a second god view with embedded persistence logic. These are data-mutating paths; bugs lose diary content, so testability here has concrete value.",
     "Extract SessionMutations (metadata rewrite / deletion / orphan purge) and pure HistoryGrouping. Note: overlaps VerlaufView.swift with SEC-3 — planner serializes."),
    ("IOS-A13", "ios", None, "iOS architecture", "—", "Worth exploring",
     "De-duplicate AudioEngine tap-callback resample body",
     "ios/Sources/Capture/AudioEngine.swift:374-445 vs :722-745; converter math x3",
     "The downsample block is copy-pasted across two tap closures; drift here silently drops audio (the file header documents past instances of exactly this bug class — this duplication has already caused real bugs).",
     "Single resample(buffer:using:state:) free function; the two taps differ only in sinks."),
    ("IOS-A14", "ios", None, "iOS architecture", "—", "Worth exploring",
     "Introduce AudioCapturing + SessionTransport protocols for test seams",
     "ios/Sources/Capture/AudioEngine.swift (no protocol), ios/Sources/Backend/ServerClient.swift (concrete URLSession + Keychain statics), coordinator .shared singletons",
     "Route-change/interruption handling — the most bug-prone logic — is unreachable from tests.",
     "Two narrow protocols, AudioCapturing and SessionTransport, injected into coordinators. Extend the pattern the pure modules already show."),

    # ---- Server architecture ----
    ("SRV-A1", "server", None, "Server architecture", "—", "Strong",
     "Add an OllamaClient adapter (seam is re-inlined 7x)",
     "llm_validator.py:21-25,288-320; fluency_checker.py:18-21,134-154; harvest_llm.py:14-16,36-38; enrichment.py:25-28,77-86; transcript_corrector.py:182-188; document_processor.py:27-34,216,406",
     "Every caller independently reads OLLAMA_* env vars, opens its own httpx.AsyncClient, hand-builds /api/chat, re-parses errors. No Ollama call is mockable without patching each module.",
     "OllamaClient adapter mirroring VoxtralClient — injectable transport, typed errors, chat(messages, *, model, num_ctx, timeout)."),
    ("SRV-A2", "server", None, "Server architecture", "—", "Strong",
     "Share one Whisper+ffmpeg audio module (implemented twice)",
     "main.py:1658-1706 vs routers/sessions.py:736-786",
     "Near-identical ffmpeg invocation and Whisper /asr POST, diverging in error strings and temp-cleanup. Deleting either helper makes it reappear in the other caller.",
     "One shared audio/AsrClient module: to_wav_16k_mono(), transcribe(), reachable()."),
    # DROPPED in grill 2026-07-04: SRV-A3 (subsumed by SRV-A1), SRV-A4 (cosmetic),
    # SRV-A9 (speculative), SRV-A10 (through-line/umbrella — its LightRAG slice is now SRV-A12).
    ("SRV-A5", "server", None, "Server architecture", "—", "Strong (low risk)",
     "Relocate ~30 shallow CRUD routes out of main.py",
     "main.py:1170-1284 (persons/terms/variations/vector), main.py:1868-2028 (org-units, relationships, role-assignments, static-entities, initiatives)",
     "Thin wrappers over db.* that add no behaviour, inflating the file that holds the deep ingest/review logic.",
     "Mechanical relocation to routers/admin.py / routers/dictionary.py. Blocked by: SEC-2 (so the moved routes inherit the app-level auth). Do not run concurrently with SEC-2 — both churn main.py routes."),
    ("SRV-A6", "server", None, "Server architecture", "—", "Strong",
     "Persist session ingest status (currently in-memory only)",
     "routers/sessions.py:83-84 (_session_status dict), transitions :297-319,404-415",
     "The pipeline has an explicit done/partial/failed/pending_analysis state machine — but the verdict lives only in a process-local dict. Restart loses all status and pending_analysis retryability; /api/sessions/{id}/status returns nothing.",
     "Persist session+segment status to a table (mirror ingest_uploads); memory becomes a cache. Interacts with UX-4's 409 semantics."),
    ("SRV-A7", "server", None, "Server architecture", "—", "Worth exploring",
     "Unify the two divergent ingest pipelines",
     "main.py:1709-1806 (/api/ingest/upload) vs routers/sessions.py:101-415 (/api/sessions)",
     "Both do audio -> ffmpeg -> Whisper -> persist, with separate helpers, separate failure bookkeeping (DB table vs in-memory dict), duplicated retry.",
     "Blocked by: SRV-A2, SRV-A6. Then express single-file ingest as a one-segment session, or share the transcribe+persist core."),
    ("SRV-A8", "server", None, "Server architecture", "—", "Worth exploring",
     "Stop raw SQL leaking out of db.py into handlers",
     "get_pool() called 20x outside db.py; inline SQL at main.py:185,750-752,786,1780-1783",
     "The repository is deep, but get_pool() leaks to 20 external call sites with inline SQL.",
     "Add the ~5 missing named query functions to db.py; make the pool private."),
    ("SRV-A11", "server", None, "Server architecture", "—", "Strong (5 minutes)",
     "Delete the last remaining n8n comment",
     "main.py:777",
     "The repo's single remaining n8n reference (a comment). diary_processor occurrences elsewhere are the legitimate Postgres DB name — leave them.",
     "Delete the comment at main.py:777."),
    ("SRV-A12", "server", None, "Server architecture", "—", "Worth exploring",
     "Extract a LightRAGClient adapter following the Voxtral template",
     "document_processor.py:62-133,159,213,404,780 (inlined LightRAG httpx calls)",
     "LightRAG is one of the weak external seams called with inlined httpx and no test coverage — the next-best adapter extraction after Ollama/Whisper. Was the concrete slice inside the dropped SRV-A10 through-line.",
     "LightRAGClient adapter mirroring voxtral_client.py (injectable transport, typed errors). Blocked by: SRV-A1, SRV-A2 (establish the template first)."),

    # ---- Security ----
    ("SEC-1", "server", "high", "Security", "High", "—",
     "Bind port 8000 to the tailnet IP, not all interfaces",
     "server/docker-compose.yml:4-5 (\"8000:8000\"), server/webapp/Dockerfile:12 (--host 0.0.0.0)",
     "The publish spec binds 0.0.0.0:8000, and Docker's iptables rules bypass ufw. Constraint #6 (Tailscale-only) is enforced by nothing. Any non-Tailscale interface exposes every endpoint — with SEC-2, full unauthenticated data/admin access.",
     "OWNER-BY-HAND: 2-line compose change, no pytest gate; the agent must NOT be given the tailnet IP/hostname (setup-plan secrets rule #3). Parameterize the publish as \"${TAILNET_IP}:8000:8000\". Ship together with SEC-2 (the Tailscale-only pair)."),
    ("SEC-2", "server", "high", "Security", "High", "—",
     "Authenticate the legacy HTMX/admin/data API",
     "77 @app.* routes in main.py without Depends(require_bearer), incl. POST /api/transcripts/delete (:737), POST /api/data/clear-dictionary (:1133), DELETE /api/admin/persons/{id} (:1186), GET /review/{transcript_id} (:218), POST /api/ingest/clear-history (:1651)",
     "routers/__init__.py:3-6 claims these stay open on the Docker network — false: they share the published port with the bearer-gated routers. All diary transcripts and destructive admin ops are open.",
     "App-level require_bearer dependency with a small allowlist (/health), or split the admin UI onto a 127.0.0.1-only app. Ship together with SEC-1 (the Tailscale-only pair). Land before SRV-A5 so the relocated routes inherit auth."),
    ("SEC-3", "ios", "high", "Security", "Medium", "—",
     "Stop exporting diary audio with URLFileProtection.none",
     "ios/Sources/Storage/AudioMerger.swift:276-277,288-290; ios/Sources/UI/Verlauf/VerlaufView.swift:1076-1078",
     "Share-staged merged M4As are readable pre-first-unlock — weaker than the accepted .completeUntilFirstUserAuthentication baseline, applied to real diary content.",
     "Use .completeUntilFirstUserAuthentication for share staging; delete temp exports after the share completes."),
    ("SEC-4", "server", None, "Security", "Low", "—",
     "Generate the Postgres password instead of hardcoding diary:diary",
     "server/docker-compose.yml:104-105",
     "Mitigated by no host port publish; becomes load-bearing the day someone maps 5432 for debugging.",
     "Generated password via .env."),
    ("SEC-5", "server", None, "Security", "Low", "—",
     "Parameterize SQL in the offline nocodb import tool",
     "server/webapp/import_nocodb.py:64,106-112,137-140,165-169,192-194",
     "Operator-run migration script; safety rests entirely on hand-rolled sql_escape().",
     "Parameterized statements via asyncpg, or unit-test sql_escape edge cases."),
    ("SEC-6", "server", None, "Security", "Low", "—",
     "Validate LLM output derived from transcripts",
     "server/webapp/harvest_llm.py:22-74 (category passed through unvalidated at :70; estimated_hours is clamped), routers/sessions.py:608-628",
     "Transcript -> Ollama -> Harvest entries / knowledge-graph narrative is an unvalidated trust boundary (prompt-injection surface, largely accepted for single-user).",
     "Allowlist category, bound lengths; document the trust boundary."),
    ("SEC-7", "ios", None, "Security", "Info", "—",
     "Log the spoken command token as .private",
     "ios/Sources/Capture/WakeWordDetector.swift:171 via Logging.swift:37",
     "Scope limited to the matched command word, but inconsistent with the codebase's own transcript-privacy rule (Logging.swift:12-13).",
     ".private interpolation for the token."),

    # ---- Usability ----
    ("UX-1", "ios", None, "Usability", "Medium", "—",
     "Surface recording interruption (banner)",
     "ios/Sources/Capture/AudioEngine.swift:664 (wasInterrupted, set at :176,278,617, zero readers); CaptureCoordinator.stop() / walkthrough banner",
     "A phone call / Siri / alarm mid-capture silently truncates the recording; the property's own doc comment promises a notice that no one implements. Resolves the IOS-A2 dead-interface-member finding (merged in the 2026-07-04 grill — wiring wasInterrupted to a banner removes the dead read-side seam).",
     "Read wasInterrupted after stop; banner 'Aufnahme wurde unterbrochen — willst du weitermachen?'"),
    ("UX-2", "ios", None, "Usability", "Low", "—",
     "Map disk-full to a localized recovery message",
     "ios/Sources/Capture/CaptureCoordinator.swift:337 -> CaptureView.swift:42-43",
     "Audio is correctly preserved (SPEC §15.2) but the user sees an interpolated NSError string.",
     "Map known domains (out-of-space) to a localized recovery-oriented message."),
    ("UX-3", "ios", None, "Usability", "Low", "—",
     "Distinguish enrichment failure copy per SPEC §15",
     "ios/Sources/Dialog/WalkthroughCoordinator.swift:2314-2323 vs SPEC.md:965-985",
     "Failure is surfaced (good) but doesn't distinguish server-unreachable from other failures ('Can't reach server. Enrichment skipped.' promise loosely met).",
     "Branch the copy on server-unreachable vs other failure to match SPEC §15."),
    ("UX-4", "ios", None, "Usability", "Low", "—",
     "Treat upload 409 as success, not permanent failure",
     "ios/Sources/Backend/SessionUploader.swift:88,208-212; server/webapp/routers/sessions.py:140-145",
     "If the 200 response is lost in transit, retry -> 409 -> entry marked permanentlyFailed although ingestion succeeded. False negative in Diagnostics, no data loss.",
     "Treat 409 as success. Client-side fix, NOT blocked (works standalone); related to SRV-A6 — cleaner once real status is persisted."),
    # DROPPED in grill 2026-07-04: UX-5 (repeat-opener — net-new feature; transcript row
    # already exists; not worth the coordinator+view churn for a single user).
    ("UX-6a", "ios", "high", "Usability", "High", "—",
     "First-run gate: server setup + permission priming",
     "ios/Sources/UI/Onboarding/_OnboardingPlaceholder.swift (stub); VoiceDiaryApp.swift:224-260 (no first-launch gate), :85 (permissions fired silently at launch)",
     "A clean install lands on the Evening tab with no server configured; first captures fail silently into the retry queue. The load-bearing bug is :85 firing permissions silently at launch. (Split from UX-6 in the 2026-07-04 grill; the full §14 10-step flow was dropped — SPEC §14 amended down to this reduced surface, see DOC-8.)",
     "First-run gate that gates the app until server URL is set + primes capture permissions explicitly. Reuse UX-7's URL validation (shares the server-setup surface; planner serializes on DebugSettingsView)."),
    ("UX-7", "ios", None, "Usability", "Medium", "—",
     "Add URL validation + onboarding entry to server setup",
     "ios/Sources/UI/Settings/DebugSettingsView.swift:172-226",
     "Good: trims input, Keychain write, /health check, 401-specific message, status pill. Gaps: no URL-format validation (malformed -> generic 'down'), default 'http://' saves to an opaque failure, and the screen lives in a file named DebugSettingsView.swift.",
     "Add URL-format validation; surface a real onboarding entry point; rename the screen. Shares the server-setup surface with UX-6a (which reuses this validation) — planner serializes on DebugSettingsView.swift."),
    ("UX-9", "ios", None, "Usability", "Medium", "—",
     "Make DisplayTimer respect Dynamic Type",
     "ios/Sources/UI/Chrome/DisplayTimer.swift:20 (fixed 64 pt + 80 pt frame)",
     "Body/title fonts now scale via Theme.font relativeTo:; the timer (drive-by counter + walkthrough listening counter) is the residual fixed-size element.",
     "@ScaledMetric or relativeTo:, or a flexible slot."),
    # DROPPED in grill 2026-07-04: UX-10 (VoiceOver) and UX-11 (reduced motion) —
    # accessibility work only pays off if the sole user enables that AT setting; owner
    # keeps UX-9 (Dynamic Type) only.
    ("UX-12", "server", None, "Usability", "Medium", "—",
     "Add empty states + save feedback to the HTMX review UI",
     "server/webapp/templates/review.html:88,118,122-124",
     "'Loading…' placeholders with no empty state, no confirmation after manual Save/entity add, no undo after addManualEntity, entity-type popup has no keyboard affordance.",
     "Add real empty states, save confirmation, undo for addManualEntity, and keyboard affordance for the entity-type popup."),
    ("UX-13a", "ios", None, "Usability", "Medium", "—",
     "Add recording + response language pickers (SPEC §12 Language & voice)",
     "SPEC.md:838-879 (Language & voice) vs LanguageSettingsView.swift",
     "The only §12 gap the owner wants built: recording-language (Auto/DE/EN) + response-language (Match/DE/EN) pickers — load-bearing for DE/EN switching, an explicit override when auto-detect guesses wrong mid-session. (Decomposed from UX-13 in the 2026-07-04 grill; the other §12 clusters — schedule, lull/empty/gap sliders, capture numerics, retention pickers — were dropped and SPEC §12 amended down, see DOC-8.)",
     "Add the two language pickers wired to the existing preference model. No retention/schedule/slider work."),

    # ---- Documentation drift (track:server: doc-only, sandboxable, no host build) ----
    ("DOC-1", "server", "high", "Documentation", "High", "—",
     "Fix stale 'implementation about to begin' / 'ios/ empty' docs",
     "CLAUDE.md:7,12; README.md:44-47; DEVELOPMENT.md:1-3,300-419 (M1–M12 all 'Planned')",
     "Reality: 99 Swift files; roughly M1–M10 substantially built. This misleads every future agent session that reads CLAUDE.md first.",
     "Update CLAUDE.md/README.md/DEVELOPMENT.md to reflect actual build state."),
    ("DOC-2", "server", None, "Documentation", "Medium", "—",
     "Add Voxtral TTS to the CLAUDE.md stack tables",
     "CLAUDE.md:154-160,164-178; SPEC.md:208 already updated",
     "Voxtral is fully implemented on both sides (ios/Sources/TTS/VoxtralTTS.swift, server/webapp/voxtral_client.py, routers/tts.py) but absent from CLAUDE.md's stack tables.",
     "Add Voxtral TTS to the on-device + server stack tables in CLAUDE.md."),
    ("DOC-3", "server", None, "Documentation", "Medium", "—",
     "Correct Gemma from 'future fallback' to implemented + primary for German",
     "CLAUDE.md:162; SPEC.md:224-226,996 vs GemmaDialogLLM.swift, VoiceDiaryApp.swift:123,155",
     "Gemma is described as a future fallback; it's implemented and primary for German (scene-phase suspend/resume wired).",
     "Update CLAUDE.md/SPEC.md to describe Gemma as implemented and primary for German."),
    ("DOC-4", "server", None, "Documentation", "Medium", "—",
     "Refresh the stale Voxtral PRD",
     "docs/prd/voxtral-tts-integration.md:3,5; DEVELOPMENT.md has no S5/M13",
     "PRD says 'Draft, awaiting triage' and references nonexistent S5/M13 milestones.",
     "Update the PRD status and remove/repoint the S5/M13 references."),
    ("DOC-5", "server", None, "Documentation", "Medium", "—",
     "Mark the DEVELOPMENT.md M11 exit criterion as met by the reduced onboarding",
     "DEVELOPMENT.md:399-406",
     "'clean install -> onboarding -> ready to capture' is satisfied by UX-6a's minimal first-run gate, not the full §14 flow (which was dropped in the 2026-07-04 grill). Update the marker accordingly.",
     "Note M11 is met by UX-6a's minimal gate (server setup + permission priming); the full §14 flow is intentionally out of scope (see DOC-8)."),
    ("DOC-6", "server", None, "Documentation", "Low", "—",
     "Reconcile deploy env-var docs with the current stack",
     "DEVELOPMENT.md:204-217; CLAUDE.md:164-178",
     "S1-era framing (n8n cleanup, 'Whisper added in S1') while routers/tts etc. already exist.",
     "Reconcile against server/.env.example + docker-compose.yml."),
    ("DOC-7", "server", None, "Documentation", "Low", "—",
     "Remove the stale Slice-05 TTSFallbackPolicy comment in VoiceRegistry",
     "ios/Sources/TTS/VoiceRegistry.swift:22",
     "The comment says 'Slice 05 will add a TTSFallbackPolicy that re-dispatches a failed Voxtral utterance' — but that fallback already shipped in VoxtralTTS.swift:149->174->180/182 and is reached from the live speak path (WalkthroughCoordinator:3990). The 2026-07-04 grill verified IOS-A11's 'unwired' bug claim was false; only this stale comment remains.",
     "Delete/update the stale forward-looking comment at VoiceRegistry.swift:22. (Doc-only; iOS file but no host build needed to change a comment.)"),
    ("DOC-8", "server", None, "Documentation", "Medium", "—",
     "Amend SPEC to the intentionally-reduced surface (§12, §14, §15)",
     "SPEC.md §12 (838-879), §14 (onboarding), §15 (TTS/enrichment rows)",
     "The 2026-07-04 grill decided several SPEC-described surfaces are intentionally NOT built for a single-user tool. Amend the spec so it stops describing unbuilt behaviour: §12 drop schedule, lull/empty-block/gap sliders, capture numerics, and retention pickers (no retention sweep exists in code); keep only the language pickers (UX-13a). §14 reduce onboarding to UX-6a's first-run gate. §15 confirm the TTS-fallback row matches the shipped Voxtral->Piper->Apple / Piper-load-fail->Apple behaviour. UX-3 stays a real fix (enrichment copy branch), not an amend.",
     "Edit SPEC.md §12/§14/§15 to match the decided reduced surface; cross-reference UX-13a and UX-6a."),
]

AREA_SECTION = {
    "iOS architecture": "§1 Architecture — iOS",
    "Server architecture": "§2 Architecture — Server",
    "Security": "§3 Security",
    "Usability": "§4 Usability",
    "Documentation": "§5 Documentation drift",
}


def gh(args, **kw):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, **kw).stdout


def ensure_labels():
    labels = [
        ("track:server", "5319E7", "Server-track work (sandboxable, pytest-verified)"),
        ("track:ios", "0E8A16", "iOS-track work (edit-only in sandbox, host-verified)"),
        ("priority:high", "B60205", "High severity or behaves-like-a-bug"),
    ]
    for name, color, desc in labels:
        if DRY:
            print(f"[label] {name}")
            continue
        try:
            gh(["label", "create", name, "--color", color, "--description", desc, "--force"])
        except subprocess.CalledProcessError as e:
            print(f"  label {name}: {e.stderr.strip()}")


def existing_finding_ids():
    out = gh(["issue", "list", "--label", "Sandcastle", "--state", "all",
              "--limit", "300", "--json", "title", "-q", ".[].title"])
    ids = set()
    for title in out.splitlines():
        if title.startswith("[") and "]" in title:
            ids.add(title[1:title.index("]")])
    return ids


def body(f):
    fid, track, prio, area, sev, strength, title, files, problem, solution = f
    return (
        f"**Finding:** `{fid}` · **Area:** {area} · **Severity:** {sev} · **Strength:** {strength} · **Track:** `{track}`\n\n"
        f"{problem}\n\n"
        f"**Files:** `{files}`\n\n"
        f"**Solution:** {solution}\n\n"
        f"---\n"
        f"Source: `docs/REVIEW-2026-07-04.md` → {AREA_SECTION[area]}. "
        f"Finding IDs are stable — reference `{fid}` in the branch/commit. "
        f"{'iOS branch: edit-only in the sandbox; verified on the macOS host (scripts/verify_agent_branch.sh) + on-device scenario.' if track=='ios' else 'Server branch: verified in-sandbox with python -m pytest server/webapp/tests/.'}"
    )


def main():
    ensure_labels()
    have = set() if DRY else existing_finding_ids()
    print(f"Existing Sandcastle findings: {sorted(have)}\n" if have else "No existing Sandcastle findings.\n")
    created = skipped = 0
    for f in F:
        fid, track, prio, title = f[0], f[1], f[2], f[6]
        if fid in have:
            skipped += 1
            continue
        full_title = f"[{fid}] {title}"
        labels = ["Sandcastle", f"track:{track}"] + (["priority:high"] if prio == "high" else [])
        if DRY:
            print(f"[create] {full_title}  labels={labels}")
            created += 1
            continue
        args = ["issue", "create", "--title", full_title, "--body", body(f)]
        for l in labels:
            args += ["--label", l]
        url = gh(args).strip()
        print(f"  created {fid}: {url}")
        created += 1
    print(f"\nDone. created={created} skipped={skipped} total_findings={len(F)}")


if __name__ == "__main__":
    main()
