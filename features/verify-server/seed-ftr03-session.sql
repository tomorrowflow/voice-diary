-- Seed for features/sessions-interrupted-recovery.md: two sessions a restart caught mid-recovery,
-- each with its one segment (s01) left `transcribing`. `ftr03-saved` also has the transcript row
-- (with its detected entities) the recovery had saved before the process died; `ftr03-unsaved` has
-- none. The bundles on disk are seeded by seed-ftr03-bundle.py.
INSERT INTO transcripts (filename, date, author, raw_text, corrected_text, detected_entities_json) VALUES
 ('ftr03-saved::s01.m4a', '2026-07-01', 'verify', 'hallo welt', 'hallo welt', '[]'::jsonb);
INSERT INTO session_ingests (session_id, received_at, state, segments) VALUES
 ('ftr03-saved', '2026-07-01T10:00:00Z', 'processing',
  '[{"segment_id":"s01","status":"transcribing","transcript_id":null}]'),
 ('ftr03-unsaved', '2026-07-01T11:00:00Z', 'processing',
  '[{"segment_id":"s01","status":"transcribing","transcript_id":null}]');
