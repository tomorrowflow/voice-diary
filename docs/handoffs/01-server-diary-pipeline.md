# Handoff 01: Server diary pipeline

Read [README.md](README.md) first (shared context, vocabulary, process rules).

**2026-09-23 strength:** Strong. **Dependency category:** ports & adapters (all remote/external).

## The candidate in one line

Collapse the two server pipelines (iOS `/api/sessions` and the HTMX SSE path) into one
**DiaryPipeline** module behind four ports: Transcriber (ffmpeg+Whisper), LLM, KnowledgeGraph
(LightRAG), Repository (Postgres). Both entry points call it.

## Friction found (as of `7ad3de1`, `server/webapp/`)

- **Two pipelines.** `routers/sessions.py` runs `_process_session` (332-415) →
  `_process_segment` (418-498) → `_run_session_document_processor` (563-628), calling six
  `document_processor` step functions in order. `main.py:458-573` (`process_document_stream`)
  re-assembles the same steps with **different error handling**: it swallows LightRAG failures
  (494), while sessions lets them propagate.
- **Divergent correction.** The HTMX path (`main.py:271-419`) applies dictionary corrections,
  vector-store few-shot examples, a fluency check, dismissal filtering and `llm_validator`. The iOS
  session path skips all of it.
- **`document_processor` is shallow.** It exposes steps, not a pipeline, so each caller has to
  know the order. `ingest_to_lightrag` hides a skeleton-sync side effect (`document_processor.py:771-778`).
- **No LLM seam.** There are 7 raw `/api/chat` call sites across 6 modules (enrichment,
  document_processor ×2, transcript_corrector, harvest_llm, fluency_checker, llm_validator). Each
  copies its own `OLLAMA_*` env block. `analyze_transcript` hardcodes the URL and the Ollama
  payload (`document_processor.py:404-418`), so the ADR-0001 opt-in has nowhere to plug in.
- **LightRAG access is split.** 7 sites; the retry and URL helpers live in `document_processor`,
  and `skeleton_sync` imports them from there. The two query sites skip retry.
- **Whisper/ffmpeg exist twice**: `main.py:1658-1707` and `sessions.py:736-786`.
- **Untestable.** Running `_process_session` would take monkeypatching ~12 attributes across 4
  modules. `tests/` has 2 files: pure helpers in `document_processor`, plus `VoxtralClient`.
- **In-repo template for the seam:** `voxtral_client.VoxtralClient` has constructor-injected
  `httpx` transport, typed errors, retry, and tests via `httpx.MockTransport`.
- Also seen, out of scope unless the user pulls them in: `submit_review` (`main.py:863-1020`,
  ~150 lines of dictionary learning inline), the Harvest cluster in `main.py`, and SQL outside
  `db.py`.

## Overlapping issues: resolve these first

This candidate largely *spans* existing Sandcastle issues. The grill has to decide whether it
supersedes them, orders them, or is just their sum.

| Issue | Finding | Relation |
|---|---|---|
| #11 | SRV-A1 OllamaClient adapter | = the LLM port (first adapter) |
| #12 | SRV-A2 shared Whisper+ffmpeg | = the Transcriber port |
| #18 | SRV-A12 LightRAGClient | = the KnowledgeGraph port |
| #14 | SRV-A6 persist ingest status | pipeline state/bookkeeping |
| #15 | SRV-A7 unify ingest pipelines | overlaps: same "two pipelines" finding, but for `/api/ingest/upload` vs `/api/sessions`, not the SSE path |
| #43 | port LLM calls to `/v1/chat/completions` | changes the LLM port's wire shape. **Has 3 commits on `sandcastle/issue-43`, merge blocked** (see note below) |
| #44 | Blindfold opt-in (ADR-0001) | = the second LLM adapter; its existence makes the LLM seam real |

Note on #43: its "merge blocked (target moved)" comment is misleading. On 2026-09-25 the actual
cause was an uncommitted `CLAUDE.md` edit in the main checkout, which blocked `git merge
--ff-only`. Check whether it has since merged.

## Open questions for the grill (not decided)

1. Is DiaryPipeline one module over #11/#12/#18, or do those adapters land first and the
   pipeline becomes the #15 follow-up?
2. Which entry points does it serve: iOS sessions and HTMX SSE only, or also
   `/api/ingest/upload` (#15)?
3. Should iOS sessions get the HTMX correction chain (dictionary, few-shot, fluency, validator)?
   That's a behaviour change, not only a refactor.
4. LightRAG failure policy: swallow (HTMX) or propagate (sessions)? One policy has to win.
5. Where does in-memory `_session_status` go (#14)?
6. Port shape: OpenAI-compatible `/v1/chat/completions` (#43) as the single LLM wire format for
   both adapters (local Ollama + Blindfold)?
7. Test surface: whole pipeline through one interface with fakes at the four ports; confirm that
   is the acceptance bar.

## Suggested skills

`mattpocock-skills:grilling`, `mattpocock-skills:codebase-design` (DEEPENING.md: ports &
adapters), `mattpocock-skills:domain-modeling` (new terms such as "narrative analysis" belong in
`CONTEXT.md`), then `mattpocock-skills:to-issues` with `track:server`.
