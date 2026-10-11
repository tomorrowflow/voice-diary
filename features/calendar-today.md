# Feature: calendar-today

Source: `server/webapp/routers/calendar.py`, `server/webapp/fixtures.py`.
Reads today's calendar from Microsoft Graph; in the isolated stack
`MSGRAPH_FIXTURE_MODE=true` makes it serve the bundled
`server/webapp/fixture_data/calendar_today.json`, shifted to the requested date.
No Entra tenant, MSAL cache or Graph token is involved.

## Drive

```bash
features/verify-server/verify.sh drive calendar-today
```

1. `GET /today/calendar?date=<today>` without bearer → **401** `missing_bearer_token`.
2. Same request with the generated bearer → **200**.

## Expected (authed)

- JSON `{"date": "<today>", "rsvp_filter": [...], "events": [...]}`; default filter is
  `accepted,tentative,organizer`; `events` non-empty, sorted by `start`.
- Each event has `graph_event_id`, `subject`, `start`/`end` (local ISO 8601), `rsvp_status`.

## Side effects

None (read-only). Fixture override: files in `<DATA_DIR>/fixtures/` win over the bundled
ones — the isolated data volume is empty, so the bundled defaults are used.

## Evidence

`calendar-today-noauth.*`, `calendar-today.*`.
