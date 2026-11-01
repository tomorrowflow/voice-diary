-- Fixed fictional cast for the isolated e2e stack (project `vd-e2e`).
--
-- Applied once to a fresh database, by the postgres init on first `up` and by
-- `e2e_stack.py reset`, after schema.sql. Every name below is invented: no
-- real person, company or product. Ids are deterministic because the database
-- is always recreated before this runs.

INSERT INTO persons (canonical_name, first_name, last_name, role, department, company, status) VALUES
  ('Jonas Falk', 'Jonas', 'Falk', 'CTO', 'Management', 'Fjordwerk', 'active'),
  ('Mira Lindqvist', 'Mira', 'Lindqvist', 'Product Lead', 'Product', 'Fjordwerk', 'active'),
  ('Henrik Aasen', 'Henrik', 'Aasen', 'Engineering Manager', 'Engineering', 'Fjordwerk', 'active'),
  ('Tilda Brandvold', 'Tilda', 'Brandvold', 'People Partner', 'HR', 'Fjordwerk', 'active'),
  ('Oskar Reinholt', 'Oskar', 'Reinholt', 'Advisory Board Member', 'Board', 'Nebelhorn Partners', 'active');

INSERT INTO person_variations (person_id, variation, variation_type, confidence) VALUES
  (1, 'Jonas Falk', 'canonical', 'high'),
  (1, 'Jonas', 'nickname', 'high'),
  (2, 'Mira Lindqvist', 'canonical', 'high'),
  (2, 'Mira', 'nickname', 'high'),
  (3, 'Henrik Aasen', 'canonical', 'high'),
  (3, 'Henrik', 'nickname', 'high'),
  (4, 'Tilda Brandvold', 'canonical', 'high'),
  (4, 'Tilda', 'nickname', 'high'),
  (5, 'Oskar Reinholt', 'canonical', 'high'),
  (5, 'Oskar', 'nickname', 'high');

INSERT INTO terms (canonical_term, category, context, status) VALUES
  ('Fjordwerk', 'company', 'Main company entity', 'active'),
  ('Nebelhorn Partners', 'company', 'Advisory firm', 'active'),
  ('Projekt Leuchtturm', 'project', 'Release planning project', 'active'),
  ('Engineering', 'department', 'Software development department', 'active');

INSERT INTO term_variations (term_id, variation) VALUES
  (1, 'Fjordwerk'), (1, 'fjordwerk'), (1, 'Fjordwerk GmbH'),
  (2, 'Nebelhorn Partners'), (2, 'Nebelhorn'),
  (3, 'Projekt Leuchtturm'), (3, 'Leuchtturm'),
  (4, 'Engineering'), (4, 'Softwareentwicklung');
