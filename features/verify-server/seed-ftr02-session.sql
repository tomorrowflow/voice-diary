-- Seed for features/sessions-retry-transcription.md: one session with a processed segment (s01)
-- and two failed ones (s02, s03). The bundle on disk is seeded by seed-ftr02-bundle.py: s02 has
-- its audio, s03 does not.
INSERT INTO session_ingests (session_id, received_at, state, segments) VALUES
 ('ftr02-recoverable', '2026-07-01T10:00:00Z', 'partial',
  '[{"segment_id":"s01","status":"processed","transcript_id":3},
    {"segment_id":"s02","status":"failed","transcript_id":null,"error":"whisper read timed out","code":"whisper_timeout","upstream":"whisper"},
    {"segment_id":"s03","status":"failed","transcript_id":null,"error":"whisper read timed out","code":"whisper_timeout","upstream":"whisper"}]');
