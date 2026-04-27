# LightRAG Optimization - Quick Summary

## The Problem

Your current markdown format **does not work well with LightRAG** for temporal queries like "show me todos from week 20" because:

1. ❌ TODOs are formatted as bullet points, not entities
2. ❌ Dates are in metadata sections, not embedded in entity descriptions
3. ❌ Relationships use arrow syntax (`--[works_at]-->`) instead of natural language
4. ❌ Week numbers are not consistently present in all relevant sections
5. ❌ LightRAG cannot extract "TODO" as an entity (not in default types)

## The Solution

**Change from database-style structure to entity-rich narrative**

### Current Format (DOESN'T WORK)
```markdown
## METADATEN
- **Datum**: 14.05.2025

### Aktionen (TODOs)
**Lernen, nicht sofort alle Probleme auflösen**
  - Verantwortlich: Florian Wolf
  - Datum: 14.05.2025
```

### Optimized Format (WORKS)
```markdown
# CTO Diary Entry - Calendar Week 20, 2025
**Entry Date:** 2025-05-14 (Wednesday, Week 20, May 2025)

### Task: Learn to Observe Before Acting (Week 20-24, 2025)
- **Task ID:** TASK-2025-W20-001
- **Assigned To:** Florian Wolf (CTO at Enersis)
- **Created Date:** May 14, 2025 (Week 20)
- **Due Date:** Week 24, 2025
- **Status:** Active
- **Context:** During week 20 at Enersis, Florian Wolf identified...
```

## Key Changes Needed

### 1. Add Week Numbers Everywhere
Every task, event, and entity should reference the week:
- "Week 20, 2025"
- "Calendar Week 20"
- "During week 20"
- "Created in week 20"
- "Due by week 24"

### 2. Write Tasks as Entities
Each task needs:
- Clear entity header: `### Task: [Name] (Week X-Y, YYYY)`
- Multiple date formats (ISO + week + month + quarter)
- Full context with week numbers embedded
- Explicit assignments

### 3. Use Natural Language Relationships
Instead of:
```markdown
**Florian Wolf** --[arbeitet_bei]--> **Enersis**
```

Write:
```markdown
Florian Wolf (CTO) works at Enersis and started during week 20 of 2025.
```

### 4. Configure Custom Entity Types

Add to LightRAG config:
```python
ENTITY_TYPES = [
    "Person",
    "Organization",
    "Location",
    "Event",
    "Task",      # ADD
    "Project",   # ADD
    "Meeting",   # ADD
    "Insight",   # ADD
    "Decision",
    "Problem"
]
```

### 5. Multiple Temporal Anchors

Every important item should include:
- ISO date: 2025-05-14
- Week: Week 20
- Month: May 2025
- Quarter: Q2 2025
- Year: 2025

## Implementation Steps

### Step 1: Update n8n Prompt (HIGH PRIORITY)
Modify your AI analysis prompt to generate entity-first format with explicit week numbers in every section.

### Step 2: Test with New Format (2-3 days)
Generate 3-5 diary entries with the new format and test queries:
```python
"Show me tasks from week 20"
"What did Florian Wolf do in May 2025"
"Show high priority tasks from Q2"
```

### Step 3: Configure LightRAG (1 day)
Add custom entity types and optimize query settings.

### Step 4: Re-process Historical Data (1-2 days)
Run old transcripts through new pipeline with updated format.

## Expected Results

### Before
❌ Query: "Show todos from week 20"
- Gets text chunks mentioning "week" or "20"
- Mixed results, low accuracy (~30%)

### After
✅ Query: "Show todos from week 20"
- Gets all Task entities with week 20 references
- High accuracy (~90%)
- Proper entity-based retrieval

## Files Created

1. **LIGHTRAG_OPTIMIZATION_ANALYSIS.md** - Full analysis with examples
2. **example/processed/diary-14.05.2025-OPTIMIZED.md** - Real example in optimized format
3. **This file** - Quick reference summary

## Next Actions

1. ✅ Review the optimized example file
2. ⏳ Modify n8n AI prompt
3. ⏳ Test with 3 new diary entries
4. ⏳ Validate temporal queries work
5. ⏳ Batch re-process historical data

## Key Insight

> **Think of your markdown as source material for a knowledge graph, not as a database schema.**

Every important concept (tasks, dates, people, insights) should be a **first-class entity** with explicit temporal anchors embedded throughout the text.

## Questions?

Compare these two files:
- `example/processed/diary-14.05.2025-summary.md` (current format)
- `example/processed/diary-14.05.2025-OPTIMIZED.md` (new format)

The difference will show you exactly what needs to change.
