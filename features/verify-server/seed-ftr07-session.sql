-- Seed for features/sessions-general-section.md: one session whose only segment, a
-- `general_section` (s01), failed. The bundle on disk is seeded by seed-ftr07-bundle.py, with
-- the audio present, so the segment reads back `recoverable: true`.
INSERT INTO session_ingests (session_id, received_at, state, segments) VALUES
 ('ftr07-general', '2026-07-01T10:00:00Z', 'failed',
  '[{"segment_id":"s01","status":"failed","transcript_id":null,"error":"whisper read timed out","code":"whisper_timeout","upstream":"whisper"}]');
