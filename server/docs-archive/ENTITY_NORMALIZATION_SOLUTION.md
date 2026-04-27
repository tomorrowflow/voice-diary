# 📝 Entity Normalization Solution for Diary Processor

## Your Requirement (Now Clear!)

You need to:
1. ✅ **Edit the transcript** to normalize entity names/terms
2. ✅ **Label entities** (PERSON, ORG, etc.) in the corrected text
3. ✅ **Store both versions** (original ASR + corrected)
4. ✅ **Track corrections** for NocoDB sync

**Example:**
```
Original ASR:  "Ich traf Tomas Koler und Monica Braitkreuz bei Enersis"
Corrected:     "Ich traf Thomas Koller und Monica Breitkreutz bei Enersys"
                        ↓               ↓                            ↓
Labels:         [PERSON: Thomas Koller] [PERSON: Monica Breitkreutz] [ORG: Enersys]
```

---

## Solution: Label Studio with Dual TextAreas ✅

### Configuration Overview

The new Label Studio config (`label-studio-config-with-editing.xml`) provides:

```
┌────────────────────────────────────────────┐
│ 🎤 Original ASR Transcript (Read-Only)     │
│ "Ich traf Tomas Koler bei Enersis"        │
└────────────────────────────────────────────┘
              ↓
┌────────────────────────────────────────────┐
│ ✏️ Corrected Transcript (Editable)         │
│ "Ich traf Thomas Koller bei Enersys"      │ ← YOU EDIT THIS
└────────────────────────────────────────────┘
              ↓
┌────────────────────────────────────────────┐
│ 🏷️ Label Entities (in Corrected Text)     │
│ [Thomas Koller: PERSON]                   │ ← LABELS AUTO-APPLY
│ [Enersys: ORGANIZATION]                   │
└────────────────────────────────────────────┘
```

### Workflow

1. **See original** - ASR transcript displayed read-only at top
2. **Edit for normalization** - Fix names/terms in middle editable area
3. **Label entities** - Select text and press hotkeys (1-8)
4. **Add notes** (optional) - Document uncertainty or corrections
5. **Submit** - All data saved together

### Data Export Structure

When you export from Label Studio, you get:

```json
{
  "data": {
    "text": "Ich traf Tomas Koler bei Enersis"  // Original ASR
  },
  "annotations": [{
    "result": [
      {
        "type": "textarea",
        "value": {
          "text": ["Ich traf Thomas Koller bei Enersys"]  // Corrected
        },
        "from_name": "corrected_text"
      },
      {
        "type": "labels",
        "value": {
          "start": 9,
          "end": 23,
          "text": "Thomas Koller",
          "labels": ["PERSON"]
        },
        "from_name": "label",
        "to_name": "entity_text"
      },
      {
        "type": "labels",
        "value": {
          "start": 28,
          "end": 35,
          "text": "Enersys",
          "labels": ["ORGANIZATION"]
        },
        "from_name": "label",
        "to_name": "entity_text"
      }
    ]
  }]
}
```

**Perfect for NocoDB sync!** You have:
- Original text (for audit trail)
- Corrected text (for downstream processing)
- Entity labels with character positions
- Mapping of variations: "Tomas Koler" → "Thomas Koller"

---

## Implementation Steps

### Step 1: Update Your Label Studio Project

**Option A: Via UI (Easiest)**

1. Go to http://localhost:8080
2. Open your "Diary Entity Review" project
3. Click **Settings** → **Labeling Interface**
4. Delete existing config
5. Paste contents from `label-studio-config-with-editing.xml`
6. Click **Save**

**Option B: Via API**

```bash
# Get project ID
PROJECT_ID=1

# Update config (if you had an API token)
curl -X PATCH http://localhost:8080/api/projects/$PROJECT_ID/ \
  -H "Authorization: Token YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @- << EOF
{
  "label_config": "$(cat label-studio-config-with-editing.xml)"
}
EOF
```

### Step 2: Test with Sample Task

**Import a test task:**

```json
{
  "text": "Tag 1 bei der Enersys. Ich habe heute die Enersys besucht und war um 14.30 mit Thomas Koler verabredet. Er hat mir kurz ein paar Dinge gezeigt. Monica Braitkreuz, die HR Managerin, war auch dabei."
}
```

**Then:**
1. Open the task
2. See original in read-only box
3. Edit corrected version: "Thomas Koler" → "Thomas Koller"
4. Select "Thomas Koller" and press `1` (PERSON)
5. Select "Monica Braitkreuz" → correct to "Monica Breitkreutz", press `1`
6. Select "Enersys" and press `2` (ORGANIZATION)
7. Submit

### Step 3: Add Ollama Auto-Labeling (Optional)

Since you already confirmed Ollama connectivity, you can add auto-labeling:

**In Label Studio UI:**
1. **Settings** → **Machine Learning**
2. **Add Model**
3. Configure:
   ```yaml
   Provider: OpenAI Compatible
   Base URL: http://host.docker.internal:11434/v1
   Model: llama3.2
   API Key: ollama
   ```
4. Add prompt:
   ```
   Extract entities from this German text and return JSON:
   {
     "entities": [
       {"text": "entity", "label": "PERSON|ORGANIZATION|...", "start": 0, "end": 5}
     ]
   }

   Text: {{text}}
   ```

**Benefit:** Entities get pre-labeled, you just review and correct!

---

## Comparison: Three Approaches

### Approach 1: Label Studio with Dual TextAreas ✅ (Recommended)

**Pros:**
- ✅ Professional annotation interface
- ✅ Handles text editing + labeling in one tool
- ✅ Batch processing (annotate multiple entries)
- ✅ Export formats (JSON, CSV, COCO)
- ✅ User management (team collaboration)
- ✅ Built-in validation
- ✅ ML integration for auto-labeling

**Cons:**
- ⚠️ Slightly complex setup (but we're already there!)
- ⚠️ Docker container required

**Best for:** Professional, scalable workflow with 100+ diary entries

---

### Approach 2: Custom HTML Interface (simple_entity_corrector.html)

**Pros:**
- ✅ Super simple (just open HTML file)
- ✅ No dependencies
- ✅ Quick corrections
- ✅ Lightweight

**Cons:**
- ⚠️ No batch processing
- ⚠️ No data persistence
- ⚠️ Manual export to NocoDB
- ⚠️ No user management
- ⚠️ Basic UI

**Best for:** Quick testing, one-off corrections, simple workflows

---

### Approach 3: Notebook-Style Interface (Jupyter/Observable)

**Pros:**
- ✅ Interactive editing
- ✅ Code + UI in one place
- ✅ Good for experimentation

**Cons:**
- ⚠️ Not designed for annotation workflows
- ⚠️ No built-in entity labeling
- ⚠️ Requires Jupyter setup

**Best for:** Data exploration, not production annotation

---

## Recommendation: Use Label Studio (Approach 1)

### Why Label Studio is the Right Tool

You already have Label Studio running, and with the new config it handles:

1. **Text normalization** ✅ (editable TextArea)
2. **Entity labeling** ✅ (NER labels)
3. **Version tracking** ✅ (original + corrected stored)
4. **Batch processing** ✅ (multiple tasks)
5. **Export to NocoDB** ✅ (JSON output)
6. **Auto-labeling** ✅ (Ollama integration)
7. **Scalability** ✅ (handles 1000+ entries)

### Migration Path

**Phase 1: Manual Review (Now)**
```
ASR → Import to Label Studio → You review & correct → Export JSON → Manual NocoDB import
```

**Phase 2: Semi-Automated (Next Month)**
```
ASR → n8n checks NocoDB → Unknown entities → Label Studio → You review → n8n auto-syncs to NocoDB
```

**Phase 3: Fully Automated (3+ Months)**
```
ASR → Entity extraction → NocoDB lookup (95% match) → Auto-process
                                              ↓
                                    5% unknown → Label Studio review
```

---

## NocoDB Sync Strategy

### What to Store

From Label Studio export, sync to NocoDB:

**Table: `diary_entries`**
```
- id
- date
- original_transcript (ASR output)
- corrected_transcript (normalized)
- entities_json (labeled entities)
- reviewed_at
- reviewed_by
```

**Table: `person_variations`**
```
- variation: "Tomas Koler"
- canonical_name: "Thomas Koller"
- first_seen: "2025-05-14"
- confidence: 1.0 (human verified)
- source: "label_studio"
```

**Table: `term_variations`**
```
- variation: "Enersis"
- canonical_term: "Enersys"
- type: "ORGANIZATION"
- first_seen: "2025-05-14"
```

### Sync Script (Python)

```python
import json
import requests

def sync_label_studio_to_nocodb(export_file):
    """Sync Label Studio annotations to NocoDB"""

    with open(export_file) as f:
        annotations = json.load(f)

    for task in annotations:
        original_text = task['data']['text']

        # Extract corrected text
        corrected_text = None
        entities = []

        for result in task['annotations'][0]['result']:
            if result['type'] == 'textarea':
                corrected_text = result['value']['text'][0]
            elif result['type'] == 'labels':
                entities.append({
                    'text': result['value']['text'],
                    'label': result['value']['labels'][0],
                    'start': result['value']['start'],
                    'end': result['value']['end']
                })

        # Find variations (where original != corrected)
        variations = find_variations(original_text, corrected_text, entities)

        # Sync to NocoDB
        for var in variations:
            if var['entity_type'] == 'PERSON':
                save_person_variation(var['original'], var['corrected'])
            else:
                save_term_variation(var['original'], var['corrected'], var['entity_type'])

def find_variations(original, corrected, entities):
    """Find where entity names were corrected"""
    variations = []

    for entity in entities:
        # Extract entity from corrected text
        corrected_entity = entity['text']

        # Find corresponding text in original
        # (using fuzzy matching or position mapping)
        original_entity = extract_from_position(original, entity['start'], entity['end'])

        if original_entity != corrected_entity:
            variations.append({
                'original': original_entity,
                'corrected': corrected_entity,
                'entity_type': entity['label']
            })

    return variations
```

---

## Next Steps (In Order)

### 1. Update Label Studio Config (5 minutes)
- [ ] Open Label Studio project settings
- [ ] Replace config with `label-studio-config-with-editing.xml`
- [ ] Save and test

### 2. Test Workflow (15 minutes)
- [ ] Import a real diary transcript
- [ ] Edit to normalize entities
- [ ] Label entities
- [ ] Export annotations
- [ ] Verify JSON structure

### 3. Connect Ollama (30 minutes)
- [ ] Add Ollama as ML backend
- [ ] Test auto-labeling
- [ ] Refine prompts for German entities

### 4. Build NocoDB Sync (1-2 hours)
- [ ] Write Python script to parse Label Studio export
- [ ] Map entities to person_variations/term_variations
- [ ] Test with sample data
- [ ] Integrate into n8n workflow

### 5. Production Workflow (ongoing)
- [ ] Process 10 diary entries
- [ ] Build entity database
- [ ] Measure auto-recognition rate
- [ ] Optimize prompts based on corrections

---

## Quick Start Commands

### Update Label Studio Config

```bash
# Copy config to clipboard (macOS)
cat /Users/frogger/Documents/GitHub/diary-processor/label-studio-config-with-editing.xml | pbcopy

# Then paste in Label Studio UI: Settings → Labeling Interface
```

### Import Test Task

```bash
# Create test task JSON
cat > /tmp/test-task.json << 'EOF'
[{
  "text": "Tag 1 bei der Enersys. Ich habe heute die Enersys besucht und war um 14.30 mit Thomas Koler verabredet. Er hat mir kurz ein paar Dinge gezeigt. Monica Braitkreuz, die HR Managerin, war auch dabei."
}]
EOF

# Import via UI: Project → Import → Upload JSON file
```

### Test Ollama Connection

```bash
# Verify Ollama is accessible from Label Studio
docker exec label-studio-app-1 curl -s http://host.docker.internal:11434/api/tags
```

---

## Troubleshooting

### Issue: "entity_text" reference not working

**Cause:** TextArea output can't be directly used as labeling source in some Label Studio versions.

**Fix:** Use a workaround with hidden text element:
```xml
<TextArea name="corrected_text" ... />
<Text name="entity_text" value="$corrected_text" hidden="true"/>
<Labels toName="entity_text">...</Labels>
```

### Issue: Edits not saving

**Cause:** `editable="true"` might not be set correctly.

**Fix:** Ensure TextArea has all attributes:
```xml
<TextArea ... editable="true" required="true"/>
```

### Issue: Can't label after editing

**Cause:** Label targets original text instead of corrected.

**Fix:** Ensure Labels target the right element:
```xml
<Labels name="label" toName="entity_text">
```

---

## Summary

✅ **Label Studio CAN handle entity normalization + labeling**
✅ **New config provides dual-field approach (original + corrected)**
✅ **Workflow: Edit text → Label entities → Export → Sync to NocoDB**
✅ **Ready to implement right now!**

---

**Want to implement this now? Just:**
1. Update your Label Studio config (paste the XML)
2. Import a test diary entry
3. Try the workflow!

Let me know when you're ready and I'll guide you through each step! 🚀
