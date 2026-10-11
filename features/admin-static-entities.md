# Feature: admin-static-entities

Source: `server/webapp/routers/admin.py`, table `static_entities` in
`server/webapp/schema.sql`. Skeleton CRUD for statuses/priorities/categories. Chosen as
the default proof route because it writes to Postgres and every effect is observable
without Whisper, Ollama or LightRAG.

## Drive

Driver subcommands `static-entity-create <name>`, `static-entity-list <name>`,
`static-entity-delete <id>` (full commands: SKILL.md → Drive), with `psql` checks via
`… exec -T postgres sh -c '…'` between them. Probe row: name `verify-ka8-probe`,
`entity_type: "Category"`.

1. `POST /api/admin/static-entities` without bearer → **401**; no row is created.
2. `POST` with bearer, body `{"name","entity_type":"Category","description"}` → **200**
   `{"status":"ok","id":<n>}`.
3. `GET /api/admin/static-entities` with bearer → **200**, list contains the probe row.
4. `psql` inside the postgres container:
   `SELECT id, name, entity_type, status FROM static_entities WHERE id = <n>` →
   `<n>|verify-<run id>|Category|active`.
5. Webapp log (JSON, one line per request) has a `/api/admin/static-entities` line with
   `status_code: 200`; the Authorization header does not appear.
6. `DELETE /api/admin/static-entities/<n>` → **200**; `SELECT count(*)` → `0`.

## Evidence

`static-entity-{create,list,delete}.txt`, `db-row-after-create.txt`,
`db-row-after-delete.txt`, and the `/api/admin/static-entities` lines in `webapp.log`.

## Notes

`entity_type` is constrained to `Status | Priority | Category` and `name` is `UNIQUE`; a
reused name or other type is a 500 from the DB, which is existing behavior — not something
to "fix" from this skill.
