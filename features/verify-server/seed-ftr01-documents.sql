-- Seed for features/documents-ingest.md: one transcript with two saved versions
-- of its processed document (ids 9001 older, 9002 newer), both for 2026-07-01
-- and not ingested.
INSERT INTO transcripts (id, filename, date, author, raw_text, corrected_text)
VALUES (9001, 'ftr01-verify::s01.m4a', '2026-07-01', 'verify', 'hallo welt', 'hallo welt');
INSERT INTO processed_documents (id, transcript_id, version, document_markdown, metadata)
VALUES (9001, 9001, 1, '# FTR-01 older narrative', '{"date": "2026-07-01"}'::jsonb),
       (9002, 9001, 2, '# FTR-01 newer narrative', '{"date": "2026-07-01"}'::jsonb);
