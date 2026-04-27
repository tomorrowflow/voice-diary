-- Seed data from current NocoDB export

INSERT INTO persons (canonical_name, first_name, last_name, role, department, company, status) VALUES
  ('Thomas Koller', 'Thomas', 'Koller', 'CEO, Head of Sales, Founder, Managing Director', 'Management', 'Enersis', 'active'),
  ('Florian Wolf', 'Florian', 'Wolf', 'CTO, Managing Director', 'Management', 'Enersis', 'active'),
  ('Monica Breitkreutz', 'Monica', 'Breitkreutz', 'HR Manager', 'HR', 'Enersis', 'active'),
  ('Christian Boiger', 'Christian', 'Boiger', 'Product Manager', 'Engineering', 'Enersis', 'active'),
  ('Michael Bez', 'Michael', 'Bez', 'Board Member', 'Board of Directors', 'EnBW', 'active')
ON CONFLICT (canonical_name) DO NOTHING;

INSERT INTO person_variations (person_id, variation, variation_type, confidence) VALUES
  (1, 'Thomas', 'nickname', 'high'),
  (1, 'Thomas Koller', 'canonical', 'high'),
  (1, 'Koller', 'nickname', 'high'),
  (2, 'Florian', 'nickname', 'high'),
  (2, 'Flo', 'nickname', 'high'),
  (2, 'Florian Wolf', 'canonical', 'high'),
  (3, 'Monica', 'nickname', 'high'),
  (3, 'Monika', 'asr_correction', 'high'),
  (3, 'Monica Breitkreutz', 'canonical', 'high'),
  (4, 'Christian', 'nickname', 'high'),
  (4, 'Christian Boiger', 'canonical', 'high'),
  (4, 'Boiger', 'nickname', 'high'),
  (5, 'Michael', 'nickname', 'high'),
  (5, 'Michael Bez', 'canonical', 'high'),
  (5, 'Bez', 'nickname', 'high')
ON CONFLICT (person_id, variation) DO NOTHING;

INSERT INTO terms (canonical_term, category, context, status) VALUES
  ('Enersis', 'company', 'Main company entity', 'active'),
  ('EnBW', 'company', 'Parent company entity', 'active'),
  ('Engineering', 'department', 'Software development department', 'active'),
  ('BYOD Policy', 'term', 'Bring Your Own Device policy', 'active'),
  ('Kubernetes', 'technology', 'Container orchestration platform', 'active'),
  ('Magic Circle', 'department', 'Internal business division within Enersis', 'active'),
  ('Internal Business Services', 'department', 'HR and operations department', 'active'),
  ('Cloud Services', 'department', 'Cloud infrastructure division', 'active'),
  ('Payment Systems', 'department', 'Payment processing division', 'active')
ON CONFLICT (canonical_term) DO NOTHING;

INSERT INTO term_variations (term_id, variation) VALUES
  (1, 'Enersis'), (1, 'enersis'), (1, 'ENERSIS'),
  (1, 'Enersis AG'), (1, 'E-nersis'), (1, 'Enersis GmbH'), (1, 'Enersys'),
  (2, 'EnBW'),
  (3, 'Engineering'), (3, 'Softwareentwicklung'), (3, 'Technikabteilung'),
  (4, 'BYOD'), (4, 'Bring Your Own Device'), (4, 'BYOD Policy'),
  (5, 'Kubernetes'), (5, 'K8s'), (5, 'k8s')
ON CONFLICT (term_id, variation) DO NOTHING;

-- Insert example transcript for testing
INSERT INTO transcripts (filename, date, author, raw_text) VALUES
  ('diary-14.05.2025', '2025-05-14'::date, 'Florian Wolf',
   'Tag 1 bei der Enersys. Eindrücke. Ich habe heute die Enersys besucht und war um 14.30 mit Thomas verabredet, hatte angenommen, dass ich anderthalb Stunden mit ihm sprechen werde. Er hat mir kurz ein paar Dinge gezeigt, wo er gerade steht. Ich erinnere, dass er mir sehr viele Zusagen gemacht hat. Ich zeig dir, ich werf dir mal die Strategie, das Strategiepapier über den Zaun. Ich binde dich ein. Hier sind die Details, die schicke ich dir. Tatsächlich leider ist davon nichts passiert. Ich meine dadurch, so ein bisschen Charakterzüge zu erkennen, dass er sehr sprunghaft ist und gleichzeitig diese Ideen, Verabredungen etc. vielleicht dem Tagesgeschäft häufig zum Abfall fallen. Schade. Ist aber ein Charakterzug, mit dem ich glaube ich umgehen kann und den werden wir auch sehr offen bearbeiten müssen, soweit ich anfange, weil mir passt es aktuell, dass ich die zusätzliche Arbeit nicht habe. Gleichzeitig finde ich es schräg, weil für mich Verabredungen eine enorme Verbindlichkeit haben und die habe ich dann noch nicht beursachtet. Thomas ist weiter super engagiert, glaube ich ganz dafür in allen Glassen, macht und tut und ist hochommittelt für die Organisation. Die halbe Stunde, die ich mit ihm hatte, war erfrischend. Ich freue mich darauf, mit ihm zusammen zu arbeiten. Das kann was werden. Ich glaube, da kann ich Einfluss nehmen und ich glaube ich muss schauen, dass ich nicht mich meinem Charakterzug hingebe sofort Dinge und die Menschen und Herausforderungen auflösen zu wollen. Da muss ich ein bisschen aufpassen. In jedem Fall war das sehr nett. Ich habe kurz mit, jetzt zum Abschluss, Christian Tiener, dem Kollegen, den ich schon wenig weiß, wie er heißt, der zum Monatsende ausschaltet, wenn ich anfange. Also insgesamt ganz viele Gesichter, eine tolle Truppe, die ich da auch heute kennenlernen durfte, außerhalb der Menschen, die ich bisher schon getroffen habe. Es sind, glaube ich, wenn ich das so sehe, super engagierte Kollegen dabei. Wir müssen schauen, den Indikator, dass es relativ spät ist. Es wird bei den Entwicklern möglicherweise eine Herausforderung langfristig, wenn wir da expandieren und weiter rekrutieren wollen und müssen. Das stelle ich jetzt aber als Aufgabe hinten an, mich irgendwann um die Rekrutierungsstrategie und die Expansionsstrategie der Technikabteilung zu kümmern oder vielmehr der Softwareentwicklung, nicht Technikabteilung. Der weitere Baustein, den ich allerdings heute noch beobachtet habe, war Monika, die sehr viel Wert auf Transparenz, Offenheit und so weiter legt. Da haben wir dann kurz in Dialog gehabt, wie machen wir das denn mit Bring Your Own Device? Da war offenbar, habe ich meinen Wunsch geäußert und Thomas meinte, das machen wir, das ist gar kein Problem. In Wirklichkeit gab es aber eine Verabredung, die er da mit tatsächlich in Frage gestellt hat. Das kam offenbar nicht so gut an, zumindest bei Monika, die einen enormen Gleichgerechtigkeitssinn hat und Sorgen möchte dafür aus ihrer AHA-Rolle, dass alle gleich bedacht werden.')
ON CONFLICT (filename, date) DO NOTHING;
