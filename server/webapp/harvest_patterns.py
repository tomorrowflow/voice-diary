"""
Analyze past Harvest time entries to build a pattern database
for auto-suggesting project/task mappings from calendar events.
"""

import re
from collections import Counter, defaultdict


def build_pattern_db(time_entries: list[dict]) -> dict:
    """
    Analyze recent Harvest time entries and extract recurring patterns.

    Returns a dict with:
      - keyword_patterns: {keyword: {project_id, project_name, task_id, task_name, typical_hours, note_template}}
      - default_project: most commonly used project/task combo
      - selbstorganisation: project/task used for gap-fill entries
      - speedy_meeting_rounding: whether 50min meetings are commonly booked as 1h
    """
    if not time_entries:
        return {
            "keyword_patterns": {},
            "default_project": None,
            "selbstorganisation": None,
            "speedy_meeting_rounding": True,
        }

    # Group entries by (project_id, task_id, normalized_note_key)
    combo_counter = Counter()
    note_combos = defaultdict(list)
    hours_by_combo = defaultdict(list)

    for entry in time_entries:
        project_id = entry.get("project", {}).get("id")
        task_id = entry.get("task", {}).get("id")
        project_name = entry.get("project", {}).get("name", "")
        task_name = entry.get("task", {}).get("name", "")
        notes = entry.get("notes", "") or ""
        hours = entry.get("hours", 0)

        combo_key = (project_id, task_id, project_name, task_name)
        combo_counter[combo_key] += 1
        note_combos[combo_key].append(notes)
        hours_by_combo[combo_key].append(hours)

    # Extract keyword patterns from recurring note+combo pairs
    keyword_patterns = {}
    for combo_key, count in combo_counter.items():
        if count < 2:
            continue
        project_id, task_id, project_name, task_name = combo_key
        notes_list = note_combos[combo_key]
        hours_list = hours_by_combo[combo_key]

        # Find common keywords in notes
        keywords = _extract_keywords(notes_list)
        avg_hours = round(sum(hours_list) / len(hours_list) * 4) / 4  # round to 15min

        # Use most common note as template
        note_counter = Counter(n.strip() for n in notes_list if n.strip())
        note_template = note_counter.most_common(1)[0][0] if note_counter else ""

        for kw in keywords:
            if kw not in keyword_patterns or count > keyword_patterns[kw].get("_count", 0):
                keyword_patterns[kw] = {
                    "project_id": project_id,
                    "project_name": project_name,
                    "task_id": task_id,
                    "task_name": task_name,
                    "typical_hours": avg_hours,
                    "note_template": note_template,
                    "_count": count,
                }

    # Clean internal count field
    for v in keyword_patterns.values():
        v.pop("_count", None)

    # Find default (most used combo)
    default_project = None
    if combo_counter:
        top = combo_counter.most_common(1)[0][0]
        default_project = {
            "project_id": top[0],
            "project_name": top[2],
            "task_id": top[1],
            "task_name": top[3],
        }

    # Detect "Selbstorganisation" pattern
    selbstorganisation = None
    for combo_key, notes_list in note_combos.items():
        all_notes_lower = " ".join(notes_list).lower()
        if "selbstorganisation" in all_notes_lower or "selbstorga" in all_notes_lower:
            project_id, task_id, project_name, task_name = combo_key
            selbstorganisation = {
                "project_id": project_id,
                "project_name": project_name,
                "task_id": task_id,
                "task_name": task_name,
            }
            break

    return {
        "keyword_patterns": keyword_patterns,
        "default_project": default_project,
        "selbstorganisation": selbstorganisation,
        "speedy_meeting_rounding": True,
    }


def _extract_keywords(notes_list: list[str]) -> list[str]:
    """Extract meaningful keywords from a list of note strings."""
    # Combine all notes, split into words, find recurring ones
    word_counter = Counter()
    stop_words = {
        "und", "mit", "für", "der", "die", "das", "von", "zu", "in", "am",
        "im", "an", "auf", "bei", "nach", "um", "als", "bis", "the", "and",
        "for", "with", "meeting", "call", "-", "/", "&", "zum", "zur",
    }
    for note in notes_list:
        if not note:
            continue
        words = re.findall(r'\b[A-Za-zÄÖÜäöüß]{3,}\b', note)
        for w in words:
            lower = w.lower()
            if lower not in stop_words:
                word_counter[lower] += 1

    total = len(notes_list)
    # Keywords that appear in ≥50% of entries
    keywords = []
    for word, count in word_counter.items():
        if count >= max(2, total * 0.5):
            keywords.append(word)

    return keywords


def match_calendar_to_pattern(
    subject: str,
    pattern_db: dict,
) -> dict | None:
    """
    Try to match a calendar event subject to a known pattern.
    Returns a pattern dict or None.
    """
    if not subject or not pattern_db.get("keyword_patterns"):
        return None

    subject_lower = subject.lower()
    subject_words = set(re.findall(r'\b[a-zäöüß]{3,}\b', subject_lower))

    best_match = None
    best_score = 0

    for keyword, pattern in pattern_db["keyword_patterns"].items():
        # Exact keyword in subject
        if keyword in subject_lower:
            score = len(keyword)  # longer matches are better
            if score > best_score:
                best_score = score
                best_match = pattern

    return best_match


def calculate_event_hours(start_iso: str, end_iso: str, speedy_rounding: bool = True) -> float:
    """Calculate hours for a calendar event, with optional speedy meeting rounding."""
    from datetime import datetime

    try:
        start = datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
        end = datetime.fromisoformat(end_iso.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return 0.5  # default

    minutes = (end - start).total_seconds() / 60

    # Speedy meeting rounding: 25min->0.5h, 50min->1h
    if speedy_rounding:
        if 20 <= minutes <= 30:
            return 0.5
        if 45 <= minutes <= 55:
            return 1.0

    # Round to nearest 15min
    hours = minutes / 60
    return max(0.25, round(hours * 4) / 4)
