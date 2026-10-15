# 05 · iOS: upload queue honours Retry-After and `retryable`, keeps the last failure

Track: ios
Type: AFK

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md) · [ADR 0003](../../adr/0003-upstream-outages-never-block-capture.md)

## What to build

`UploadOutcome.classify` keeps its 409, 400/404/422 and default rules and additionally: waits at least `Retry-After` when that is longer than the backoff step; treats `retryable: false` as non-automatic, so the entry is not marked permanent and waits until the next foreground or a settings change. `SessionUploader.QueueEntry` gains an optional last-failure code (a custom decoder default keeps old `upload_queue.json` files readable). Audio is never deleted on a failure. Expose the last failure on `pending()` so slice 08 can display it.

Update SPEC §10.6.

## Acceptance criteria

- [ ] `UploadOutcome` tests: `Retry-After` longer than the backoff wins, shorter is ignored; `retryable: false` is neither retried automatically nor marked permanent; the existing 409/400/404/422 rules are unchanged (extends `UploadOutcomeTests`).
- [ ] A queue file written before this change decodes with a nil last-failure code.
- [ ] After a Whisper-down rejection the entry is rescheduled, keeps its audio paths, and records `whisper_unavailable`.
- [ ] SPEC §10.6 updated; `ios` build and tests pass.

## Blocked by

- [01 · Failure contract: helper, Whisper preflight, segment codes](./01-failure-contract-whisper-sessions.md)
- [04 · iOS: parse the contract, failure copy, spoken enrichment lines](./04-ios-parse-contract-and-copy.md)
