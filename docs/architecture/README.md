# Architecture map

SeeCode JSON specs that describe Voice Diary. The JSON is the source of truth: agents read it as
context and a viewer renders it for the operator. Rendered `*.html` is never committed (see
`.gitignore`).

| Spec | Type | Shows |
| --- | --- | --- |
| `overview.json` | `high-level` | The whole system for a non-engineer: iPhone app, server, external services |
| `server.json` | `architecture` | `server/webapp` and `server/voxtral-gate` |
| `ios.json` | `architecture` | `ios/Sources` and the widget extension |
| `deployment.json` | `deployment` | What runs where, from `server/docker-compose.yml` and the Dockerfiles |

## Rules

- Never invent components. Every node and edge must exist in the code or compose file today.
- Mark anything inferred rather than seen as `"kind": "optional"`, and say so in the card or PR.
- Patch specs instead of rewriting them: use `--patch` with small changes, at most 3 rounds per spec.
- Keep evidence as `file:line`: each non-obvious node or edge carries `{"id", "file", "line"}`
  with a repo-relative path to a line that exists at HEAD. Edge ids are `from>to`.
- Stay within the budget: at most 9 nodes and 12 edges per spec. Split a spec rather than exceed it.
- Update the map only from an `arch-map` card, when the code and the map have drifted.

## Render

```
node ~/.claude/skills/seecode/scripts/seecode.mjs render docs/architecture
```

Run it exactly in this form from the repo root. Every spec must return `ok:true` with no `W_`
warning. Settings live in `.seecode/config.json` (`outputDir`, `fonts`).
