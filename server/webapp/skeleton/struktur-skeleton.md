ENTITY: Status-Offen
TYPE: Status
PROPERTIES: {status_name: "Offen", can_transition_to: ["InArbeit", "Blockiert"], is_active: "yes"}
DESCRIPTION: Task oder Projekt wurde noch nicht begonnen und wartet auf Start
ALIASES: ["Status-Offen", "Offen", "Open", "Not Started"]

ENTITY: Status-InArbeit
TYPE: Status
PROPERTIES: {status_name: "InArbeit", can_transition_to: ["Abgeschlossen", "Blockiert", "Offen"], is_active: "yes"}
DESCRIPTION: Task oder Projekt ist aktuell in Bearbeitung und wird aktiv daran gearbeitet
ALIASES: ["Status-InArbeit", "In Arbeit", "InArbeit", "In Progress", "WIP"]

ENTITY: Status-Abgeschlossen
TYPE: Status
PROPERTIES: {status_name: "Abgeschlossen", can_transition_to: [], is_active: "no"}
DESCRIPTION: Task oder Projekt wurde erfolgreich abgeschlossen und ist fertiggestellt
ALIASES: ["Status-Abgeschlossen", "Abgeschlossen", "Fertig", "Done", "Completed", "Erledigt"]

ENTITY: Status-Blockiert
TYPE: Status
PROPERTIES: {status_name: "Blockiert", can_transition_to: ["Offen", "InArbeit"], is_active: "yes"}
DESCRIPTION: Task oder Projekt ist blockiert und kann nicht fortgesetzt werden bis Blocker aufgelöst ist
ALIASES: ["Status-Blockiert", "Blockiert", "Blocked", "Wartend", "Waiting"]

ENTITY: Kategorie-Performance
TYPE: Achievement-Category
PROPERTIES: {category_name: "Performance", domain: "Technical", priority: "high"}
DESCRIPTION: Erfolge im Bereich Performance-Optimierung, Geschwindigkeit, Skalierung und Effizienz
ALIASES: ["Kategorie-Performance", "Performance", "Performance-Optimierung", "Speed", "Scalability"]

ENTITY: Kategorie-Security
TYPE: Achievement-Category
PROPERTIES: {category_name: "Security", domain: "Technical", priority: "critical"}
DESCRIPTION: Erfolge im Bereich Sicherheit, Datenschutz, Compliance und Security-Maßnahmen
ALIASES: ["Kategorie-Security", "Security", "Sicherheit", "InfoSec", "Cybersecurity"]

ENTITY: Kategorie-Team
TYPE: Achievement-Category
PROPERTIES: {category_name: "Team", domain: "People", priority: "high"}
DESCRIPTION: Erfolge im Bereich Team-Entwicklung, Zusammenarbeit, Onboarding und Team-Building
ALIASES: ["Kategorie-Team", "Team", "Team-Development", "Collaboration", "Teamwork"]

ENTITY: Kategorie-Prozess
TYPE: Achievement-Category
PROPERTIES: {category_name: "Prozess", domain: "Operations", priority: "medium"}
DESCRIPTION: Erfolge im Bereich Prozess-Verbesserung, Automatisierung, DevOps und Workflow-Optimierung
ALIASES: ["Kategorie-Prozess", "Prozess", "Process", "Process-Improvement", "DevOps"]

ENTITY: Kategorie-Business
TYPE: Achievement-Category
PROPERTIES: {category_name: "Business", domain: "Strategic", priority: "high"}
DESCRIPTION: Erfolge im Bereich Business-Impact, Revenue, Cost-Savings und strategische Ziele
ALIASES: ["Kategorie-Business", "Business", "Business-Impact", "Revenue", "ROI"]

RELATIONSHIP: Status-Offen --[kann_wechseln_zu]--> Status-InArbeit
DATE: 2025-11-25
PROPERTIES: {transition_type: "start", requires_action: "yes", common: "yes"}
CONTEXT: Ein offenes TODO/Projekt kann in Bearbeitung genommen werden
BIDIRECTIONAL: no

RELATIONSHIP: Status-Offen --[kann_wechseln_zu]--> Status-Blockiert
DATE: 2025-11-25
PROPERTIES: {transition_type: "block", requires_action: "yes", common: "no"}
CONTEXT: Ein offenes TODO/Projekt kann blockiert werden wenn Abhängigkeiten nicht erfüllt sind
BIDIRECTIONAL: no

RELATIONSHIP: Status-InArbeit --[kann_wechseln_zu]--> Status-Abgeschlossen
DATE: 2025-11-25
PROPERTIES: {transition_type: "complete", requires_action: "yes", common: "yes"}
CONTEXT: Ein TODO/Projekt in Bearbeitung kann abgeschlossen werden
BIDIRECTIONAL: no

RELATIONSHIP: Status-InArbeit --[kann_wechseln_zu]--> Status-Blockiert
DATE: 2025-11-25
PROPERTIES: {transition_type: "block", requires_action: "yes", common: "yes"}
CONTEXT: Ein TODO/Projekt in Bearbeitung kann blockiert werden wenn Probleme auftreten
BIDIRECTIONAL: no

RELATIONSHIP: Status-InArbeit --[kann_wechseln_zu]--> Status-Offen
DATE: 2025-11-25
PROPERTIES: {transition_type: "revert", requires_action: "yes", common: "no"}
CONTEXT: Ein TODO/Projekt in Bearbeitung kann zurück auf offen gesetzt werden
BIDIRECTIONAL: no

RELATIONSHIP: Status-Blockiert --[kann_wechseln_zu]--> Status-Offen
DATE: 2025-11-25
PROPERTIES: {transition_type: "unblock", requires_action: "yes", common: "yes"}
CONTEXT: Ein blockiertes TODO/Projekt kann wieder geöffnet werden wenn Blocker aufgelöst
BIDIRECTIONAL: no

RELATIONSHIP: Status-Blockiert --[kann_wechseln_zu]--> Status-InArbeit
DATE: 2025-11-25
PROPERTIES: {transition_type: "resume", requires_action: "yes", common: "yes"}
CONTEXT: Ein blockiertes TODO/Projekt kann direkt wieder in Bearbeitung genommen werden
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Performance --[ist_verwandt_mit]--> Kategorie-Prozess
DATE: 2025-11-25
PROPERTIES: {relationship_strength: "high", reason: "Process optimization often improves performance"}
CONTEXT: Performance-Verbesserungen und Prozess-Optimierungen sind oft eng miteinander verbunden
BIDIRECTIONAL: yes

RELATIONSHIP: Kategorie-Security --[ist_verwandt_mit]--> Kategorie-Prozess
DATE: 2025-11-25
PROPERTIES: {relationship_strength: "medium", reason: "Security requires proper processes"}
CONTEXT: Security-Maßnahmen erfordern oft neue oder verbesserte Prozesse
BIDIRECTIONAL: yes

RELATIONSHIP: Kategorie-Team --[ist_verwandt_mit]--> Kategorie-Prozess
DATE: 2025-11-25
PROPERTIES: {relationship_strength: "high", reason: "Team development improves processes"}
CONTEXT: Team-Entwicklung führt oft zu besseren Prozessen und Zusammenarbeit
BIDIRECTIONAL: yes

RELATIONSHIP: Kategorie-Business --[beeinflusst_durch]--> Kategorie-Performance
DATE: 2025-11-25
PROPERTIES: {impact_type: "positive", strength: "high"}
CONTEXT: Performance-Verbesserungen haben direkten Business-Impact
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Business --[beeinflusst_durch]--> Kategorie-Security
DATE: 2025-11-25
PROPERTIES: {impact_type: "positive", strength: "high"}
CONTEXT: Security-Erfolge haben direkten Business-Impact durch Risikominimierung
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Business --[beeinflusst_durch]--> Kategorie-Team
DATE: 2025-11-25
PROPERTIES: {impact_type: "positive", strength: "medium"}
CONTEXT: Team-Erfolge haben indirekten Business-Impact durch bessere Produktivität
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Performance --[ist_teil_von]--> Technical-Domain
DATE: 2025-11-25
CONTEXT: Performance ist eine technische Achievement-Kategorie
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Security --[ist_teil_von]--> Technical-Domain
DATE: 2025-11-25
CONTEXT: Security ist eine technische Achievement-Kategorie
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Team --[ist_teil_von]--> People-Domain
DATE: 2025-11-25
CONTEXT: Team ist eine People-fokussierte Achievement-Kategorie
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Prozess --[ist_teil_von]--> Operations-Domain
DATE: 2025-11-25
CONTEXT: Prozess ist eine Operations-fokussierte Achievement-Kategorie
BIDIRECTIONAL: no

RELATIONSHIP: Kategorie-Business --[ist_teil_von]--> Strategic-Domain
DATE: 2025-11-25
CONTEXT: Business ist eine strategische Achievement-Kategorie
BIDIRECTIONAL: no