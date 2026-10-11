# Feature: sessions-dates

Source: `server/webapp/routers/sessions.py` (`session_dates`). Lists distinct recording
dates that already have a transcript; the iOS walkthrough date picker uses it.

## Drive

```bash
features/verify-server/verify.sh drive sessions-dates
```

1. `GET /api/sessions/dates` without bearer → **401**.
2. With bearer → **200**, body `{"dates": [...]}` (empty array on a fresh stack).
3. `GET /api/sessions/dates?date_from=not-a-date` with bearer → **400**
   `{"detail": "invalid_date_from"}`.

## Side effects

Read-only SQL against `transcripts` in the stack's Postgres (the schema is applied by the
webapp lifespan on startup, so a 200 also shows the schema/DB path works).

## Evidence

`sessions-dates-noauth.*`, `sessions-dates.*`, `sessions-dates-bad.*`.
