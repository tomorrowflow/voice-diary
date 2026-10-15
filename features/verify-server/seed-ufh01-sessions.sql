-- Seed for features/sessions-upstream-failure.md: one session_ingests row written
-- before the failure contract (segments without code/upstream) and one after.
INSERT INTO session_ingests (session_id, received_at, state, segments) VALUES
 ('ufh01-legacy', '2026-07-01T10:00:00Z', 'partial',
  '[{"segment_id":"s01","status":"failed","transcript_id":null,"error":"whisper exploded"},
    {"segment_id":"s02","status":"pending_analysis","transcript_id":3,"error":"analysis_pending: ollama unreachable"}]'),
 ('ufh01-coded', '2026-07-01T10:00:00Z', 'partial',
  '[{"segment_id":"s01","status":"failed","transcript_id":null,"error":"whisper read timed out","code":"whisper_timeout","upstream":"whisper"},
    {"segment_id":"s02","status":"pending_analysis","transcript_id":3,"error":"analysis_pending: refused","code":"ollama_unavailable","upstream":"ollama"}]');
