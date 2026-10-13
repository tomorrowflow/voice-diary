# Server feature map

> The iOS app has its own map and skill: `features/ios/README.md` and `features/verify-ios/SKILL.md`.

Route-focused maps for the `verify-server` skill (`features/verify-server/SKILL.md`;
move it to `.claude/skills/verify-server/` to expose it as a project skill). The stack is
`features/verify-server/compose.verify.yml` (Compose project `vd-verify`) and routes are
driven by `features/verify-server/drive.py` from a `driver` container. Each file says how to drive one route group
against the isolated Compose stack and what proves it worked.

| Feature | Route(s) | Auth | Side effect to observe | Drive target |
|---|---|---|---|---|
| [health](health.md) | `GET /health` | none (by design) | upstream probe map | `health` |
| [calendar-today](calendar-today.md) | `GET /today/calendar` | bearer | none (read); fixture events | `calendar-today` |
| [sessions-dates](sessions-dates.md) | `GET /api/sessions/dates` | bearer | Postgres read; 400 on bad date | `sessions-dates` |
| [admin-static-entities](admin-static-entities.md) | `POST/GET/DELETE /api/admin/static-entities` | bearer | Postgres row + request log line | `admin-static-entities` |

## Not mapped yet

- `POST /api/sessions` (session ingest) — needs a real Whisper sidecar and a real
  audio bundle; add once the stack can start Whisper without a GPU.
- `/api/tts/*` — needs Voxtral (GPU, gated HF weights).
- `/lightrag/*`, `/email/search` — need LightRAG / Graph; not available in the isolated stack.
- HTMX review/admin pages in `main.py` — same bearer; add per-page maps when needed.

## Ground rules

- Routes are driven through the real webapp container; nothing is mocked at the HTTP
  boundary. The only stand-in is the server's own `MSGRAPH_FIXTURE_MODE`.
- The 401-without-bearer check comes first for every authed route (`routers/auth.py`
  fails closed: unset token → 503, missing → 401 `missing_bearer_token`,
  wrong → 401 `invalid_bearer_token`).
- Evidence for a run lives in `features/evidence/<run>/` and survives cleanup.
  It is git-ignored; commit a run on purpose with `git add -f`.
- A route that is not in the table is not verified by this skill.
