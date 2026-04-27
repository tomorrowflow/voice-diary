"""
4-pass entity detection engine.

Pass 1: Exact case-insensitive match against known variations -> auto-correct
Pass 2: Normalized match (strip diacritics, normalize whitespace) -> auto-correct
Pass 3: Levenshtein distance <= 2 for likely ASR errors -> flag as "suggested"
Pass 4: First-name-only resolution -> auto-correct if unambiguous,
        flag as "ambiguous" with candidates if multiple matches
"""

import json
import re
from dataclasses import asdict, dataclass, field

from Levenshtein import distance as levenshtein_distance
from unidecode import unidecode

CATEGORY_TO_TYPE = {
    "company": "ORGANIZATION",
    "department": "ORGANIZATION",
    "technology": "TECHNOLOGY",
    "term": "TERM",
    "project": "PROJECT",
    "location": "LOCATION",
    "event": "EVENT",
    "concept": "CONCEPT",
}

GERMAN_STOPWORDS = {
    # pronouns
    "ich", "du", "er", "sie", "es", "wir", "ihr",
    "mich", "mir", "dich", "dir", "ihm", "ihn",
    "uns", "euch", "sich", "mein", "dein", "sein",
    # articles / demonstratives
    "der", "die", "das", "dem", "den", "des",
    "ein", "eine", "einer", "einem", "einen",
    "dieser", "diese", "dieses", "jeder", "jede",
    # conjunctions / particles / adverbs
    "und", "oder", "aber", "dass", "wenn", "weil",
    "also", "dann", "denn", "doch", "noch", "schon",
    "sehr", "ganz", "nur", "eben", "halt", "wohl",
    "etwa", "gar", "mal", "gerade", "bereits",
    "da", "wo", "so", "ja", "nun", "nie", "oft",
    "dabei", "damit", "darum", "davon", "dafür",
    "dahin", "daher", "danach", "darauf", "daraus",
    "daran", "darin", "darüber", "darunter", "dazu",
    "hier", "dort", "oben", "unten",
    # prepositions
    "mit", "von", "bei", "für", "auf", "aus",
    "nach", "über", "unter", "vor", "zwischen",
    "durch", "gegen", "ohne", "bis", "seit",
    # verbs (common forms)
    "ist", "hat", "war", "sind", "haben", "werden",
    "kann", "will", "soll", "muss", "darf",
    "wird", "würde", "könnte", "sollte", "müsste",
    "habe", "hatte", "wäre", "hätte",
    "sein", "machen", "gehen", "kommen", "sagen",
    "finde", "glaube", "denke", "meine", "weiß",
    # common nouns (things that appear often in diary text)
    "Tag", "Tage", "Tagen", "Zeit", "Mal",
    "Jahr", "Jahre", "Monat", "Monate", "Woche", "Wochen",
    "Dinge", "Details", "Ideen", "Frage", "Fragen",
    "Thema", "Themen", "Punkt", "Punkte",
    "Ende", "Anfang", "Teil", "Seite",
    "Arbeit", "Stelle", "Weise",
    # common adjectives
    "guter", "gute", "gutes", "neuer", "neue", "neues",
    "erster", "erste", "erstes", "letzter", "letzte",
    "viel", "viele", "wenig", "wenige",
    "mehr", "andere", "anderer", "anderes",
}

CATEGORY_CONTEXT_KEYWORDS = {
    "department": {"team", "abteilung", "meeting", "leiter", "head", "lead",
                   "gruppe", "bereich", "org", "organization"},
    "technology": {"server", "deploy", "container", "stack", "migration",
                   "cluster", "infrastructure", "cloud", "api", "service",
                   "tool", "platform", "system", "software", "version",
                   "update", "install", "config", "setup", "infrastruktur"},
    "concept": {"meeting", "sprint", "workshop", "methode", "prozess",
                "agile", "ansatz", "strategie", "planung", "review",
                "retro", "standup", "daily", "backlog", "board"},
    "project": {"projekt", "milestone", "phase", "rollout", "launch",
                "timeline", "release", "deadline", "scope", "epic",
                "feature", "roadmap", "plan", "iteration"},
    "company": {"firma", "partner", "kunde", "vertrag", "zusammenarbeit",
                "gmbh", "ag", "inc", "unternehmen", "dienstleister",
                "anbieter", "lieferant"},
}


def _is_sentence_start(text: str, pos: int) -> bool:
    """Check if pos is at the start of a sentence."""
    if pos == 0:
        return True
    # Look backwards past whitespace for sentence-ending punctuation or newline
    i = pos - 1
    while i >= 0 and text[i] == " ":
        i -= 1
    if i < 0:
        return True
    return text[i] in ".?!\n"


def _should_match_term(variation: str, matched_text: str, pos: int, text: str) -> bool:
    """Decide whether a short term variation should produce a match."""
    var_len = len(variation)

    # Long variations always match
    if var_len >= 7:
        return True

    # Check stopwords for all short variations
    if matched_text in GERMAN_STOPWORDS or matched_text.lower() in GERMAN_STOPWORDS:
        return False

    at_sentence_start = _is_sentence_start(text, pos)

    if var_len <= 2:
        # Require exact case match for very short terms (e.g. "PM", "MC")
        return matched_text == variation

    if var_len <= 4:
        # Require uppercase presence (not all-lowercase)
        # But if at sentence start and variation is not all-caps, reject
        # (German capitalizes first word of sentence)
        if matched_text.islower():
            return False
        if at_sentence_start and not variation.isupper():
            return False
        return True

    # 5-6 chars: just the stopword check (already done above)
    # But if at sentence start and variation is not all-caps, be skeptical
    if at_sentence_start and not variation.isupper():
        # Only reject if the matched text is title-case (could be sentence-start capitalization)
        if matched_text[0].isupper() and matched_text[1:].islower():
            return False

    return True


def _has_context_support(text: str, start: int, end: int, category: str, window: int = 50) -> bool:
    """Check if surrounding text contains category-relevant keywords."""
    keywords = CATEGORY_CONTEXT_KEYWORDS.get(category)
    if not keywords:
        # No keywords defined for this category — permissive by default
        return True

    window_start = max(0, start - window)
    window_end = min(len(text), end + window)
    surrounding = text[window_start:window_end].lower()

    return any(kw in surrounding for kw in keywords)


@dataclass
class DetectedEntity:
    start: int
    end: int
    original_text: str
    canonical: str
    entity_type: str  # PERSON, ORGANIZATION, TERM, TECHNOLOGY, etc.
    match_type: str  # exact, variation, normalized, fuzzy, first_name, manual
    confidence: str  # high, medium, low
    status: str  # auto-matched, suggested, ambiguous, new-entity
    dictionary_id: int | None = None
    source: str = "term"  # person or term
    role: str = ""
    candidates: list = field(default_factory=list)
    llm_validated: bool = False
    llm_reason: str = ""
    llm_suggested: bool = False

    def to_dict(self) -> dict:
        return asdict(self)


def normalize_text(text: str) -> str:
    """Strip diacritics, normalize whitespace, lowercase."""
    return re.sub(r"\s+", " ", unidecode(text).lower().strip())


def is_word_boundary(text: str, start: int, end: int) -> bool:
    """Check if the match is at word boundaries."""
    before = text[start - 1] if start > 0 else " "
    after = text[end] if end < len(text) else " "
    return not before.isalnum() and not after.isalnum()


def _extract_variations(variations) -> list[str]:
    """Normalize variations from DB (may be JSON string, list of dicts, or list of strings)."""
    if isinstance(variations, str):
        variations = json.loads(variations)
    result = []
    for v in variations:
        if isinstance(v, dict):
            result.append(v.get("variation", v.get("text", "")))
        else:
            result.append(str(v))
    return result


def detect_entities(
    text: str,
    persons: list[dict],
    terms: list[dict],
) -> list[DetectedEntity]:
    """Run 4-pass detection against the dictionary."""

    detected: list[DetectedEntity] = []
    text_lower = text.lower()
    text_normalized = normalize_text(text)

    # --- Build dehyphenated text with position mapping for hyphen-insensitive matching ---
    # e.g. "To-Do" at pos 50-55 → "ToDo" in dehyph text, with mapping back to original positions
    _dehyph_chars: list[str] = []
    _dehyph_to_orig: list[int] = []  # _dehyph_to_orig[i] = original text position of char i
    for _i, _c in enumerate(text):
        if _c != "-":
            _dehyph_chars.append(_c)
            _dehyph_to_orig.append(_i)
    text_dehyph_lower = "".join(_dehyph_chars).lower()

    # --- Build first-name ambiguity index for Pass 4 ---
    first_name_index: dict[str, list[dict]] = {}
    for person in persons:
        fn = (person.get("first_name") or "").strip().lower()
        if fn:
            first_name_index.setdefault(fn, []).append(person)

    # --- TERM MATCHING (Pass 1 + 2) ---
    for term in terms:
        canonical = term["canonical_term"]
        category = term.get("category", "term")
        entity_type = CATEGORY_TO_TYPE.get(category, "TERM")
        variations = _extract_variations(term.get("variations", []))
        # Always include canonical name so it's matched directly
        if canonical and canonical not in variations:
            variations.append(canonical)
        variations.sort(key=len, reverse=True)

        for variation in variations:
            if not variation:
                continue
            var_lower = variation.lower()
            idx = 0
            while True:
                idx = text_lower.find(var_lower, idx)
                if idx == -1:
                    break
                if is_word_boundary(text, idx, idx + len(variation)):
                    original = text[idx : idx + len(variation)]

                    # Skip false-positive-prone short matches
                    if not _should_match_term(variation, original, idx, text):
                        idx += len(variation)
                        continue

                    # Context check: downgrade short matches without context
                    status = "auto-matched"
                    confidence = "high"
                    if len(variation) < 7 and not _has_context_support(
                        text, idx, idx + len(variation), category
                    ):
                        status = "suggested"
                        confidence = "medium"

                    is_exact = original == canonical
                    detected.append(
                        DetectedEntity(
                            start=idx,
                            end=idx + len(variation),
                            original_text=original,
                            canonical=canonical,
                            entity_type=entity_type,
                            match_type="exact" if is_exact else "variation",
                            confidence=confidence,
                            status=status,
                            dictionary_id=term["id"],
                            source="term",
                        )
                    )
                idx += len(variation)

            # Pass 1b: Dehyphenated match (e.g. "To-Do" ↔ "ToDo")
            var_dehyph = var_lower.replace("-", "")
            if var_dehyph != var_lower:  # variation itself had hyphens
                d_idx = 0
                while True:
                    d_idx = text_dehyph_lower.find(var_dehyph, d_idx)
                    if d_idx == -1:
                        break
                    orig_start = _dehyph_to_orig[d_idx]
                    orig_end = _dehyph_to_orig[d_idx + len(var_dehyph) - 1] + 1
                    if is_word_boundary(text, orig_start, orig_end):
                        original = text[orig_start:orig_end]
                        if not _should_match_term(variation, original, orig_start, text):
                            d_idx += len(var_dehyph)
                            continue
                        status = "auto-matched"
                        confidence = "high"
                        if len(variation) < 7 and not _has_context_support(
                            text, orig_start, orig_end, category
                        ):
                            status = "suggested"
                            confidence = "medium"
                        detected.append(
                            DetectedEntity(
                                start=orig_start,
                                end=orig_end,
                                original_text=original,
                                canonical=canonical,
                                entity_type=entity_type,
                                match_type="variation",
                                confidence=confidence,
                                status=status,
                                dictionary_id=term["id"],
                                source="term",
                            )
                        )
                    d_idx += len(var_dehyph)
            elif text_dehyph_lower != text_lower:
                # Variation has no hyphens but text might (e.g. text "To-Do", var "ToDo")
                d_idx = 0
                while True:
                    d_idx = text_dehyph_lower.find(var_dehyph, d_idx)
                    if d_idx == -1:
                        break
                    orig_start = _dehyph_to_orig[d_idx]
                    orig_end = _dehyph_to_orig[d_idx + len(var_dehyph) - 1] + 1
                    # Skip if this range was already matched by the exact search above
                    if orig_end - orig_start == len(variation):
                        # Same length means no hyphens were stripped — already handled
                        d_idx += len(var_dehyph)
                        continue
                    if is_word_boundary(text, orig_start, orig_end):
                        original = text[orig_start:orig_end]
                        if not _should_match_term(variation, original, orig_start, text):
                            d_idx += len(var_dehyph)
                            continue
                        status = "auto-matched"
                        confidence = "high"
                        if len(variation) < 7 and not _has_context_support(
                            text, orig_start, orig_end, category
                        ):
                            status = "suggested"
                            confidence = "medium"
                        detected.append(
                            DetectedEntity(
                                start=orig_start,
                                end=orig_end,
                                original_text=original,
                                canonical=canonical,
                                entity_type=entity_type,
                                match_type="variation",
                                confidence=confidence,
                                status=status,
                                dictionary_id=term["id"],
                                source="term",
                            )
                        )
                    d_idx += len(var_dehyph)

        # Pass 2: Normalized match for terms
        canonical_normalized = normalize_text(canonical)
        for variation in variations:
            if not variation:
                continue
            var_normalized = normalize_text(variation)
            if var_normalized == var_lower:
                continue  # Already covered by Pass 1
            idx = 0
            while True:
                idx = text_normalized.find(var_normalized, idx)
                if idx == -1:
                    break
                # Map normalized position back to original text (approximate)
                original = text[idx : idx + len(variation)]
                if is_word_boundary(text, idx, idx + len(variation)):
                    # Skip false-positive-prone short matches
                    if not _should_match_term(variation, original, idx, text):
                        idx += len(variation)
                        continue

                    # Context check: downgrade short matches without context
                    status = "auto-matched"
                    confidence = "high"
                    if len(variation) < 7 and not _has_context_support(
                        text, idx, idx + len(variation), category
                    ):
                        status = "suggested"
                        confidence = "medium"

                    detected.append(
                        DetectedEntity(
                            start=idx,
                            end=idx + len(variation),
                            original_text=original,
                            canonical=canonical,
                            entity_type=entity_type,
                            match_type="normalized",
                            confidence=confidence,
                            status=status,
                            dictionary_id=term["id"],
                            source="term",
                        )
                    )
                idx += len(variation)

    # --- PERSON MATCHING (Pass 1 + 2 + 4) ---
    for person in persons:
        canonical = person["canonical_name"]
        variations = _extract_variations(person.get("variations", []))
        # Always include canonical (full) name so multi-word names are matched
        if canonical and canonical not in variations:
            variations.append(canonical)
        variations.sort(key=len, reverse=True)

        for variation in variations:
            if not variation:
                continue
            var_lower = variation.lower()

            # Skip variations that are common German words (stopwords)
            if var_lower in GERMAN_STOPWORDS:
                continue
            # Skip very short variations (≤2 chars) unless they're all-uppercase
            # abbreviations (e.g. "PM") — common words like "Da" are not names
            if len(variation) <= 2 and not variation.isupper():
                continue

            idx = 0
            while True:
                idx = text_lower.find(var_lower, idx)
                if idx == -1:
                    break

                match_len = len(variation)
                if match_len < 5 and not is_word_boundary(
                    text, idx, idx + match_len
                ):
                    idx += 1
                    continue

                original = text[idx : idx + match_len]
                is_exact = original == canonical
                is_first_name = var_lower == (
                    person.get("first_name") or ""
                ).lower()

                # --- Pass 4: First-name ambiguity check ---
                if is_first_name and var_lower in first_name_index:
                    matches = first_name_index[var_lower]
                    if len(matches) > 1:
                        # AMBIGUOUS: multiple persons share this first name
                        detected.append(
                            DetectedEntity(
                                start=idx,
                                end=idx + match_len,
                                original_text=original,
                                canonical=original,
                                entity_type="PERSON",
                                match_type="first_name",
                                confidence="medium",
                                status="ambiguous",
                                dictionary_id=None,
                                source="person",
                                candidates=[
                                    {
                                        "id": m["id"],
                                        "canonical": m["canonical_name"],
                                        "role": m.get("role", ""),
                                        "company": m.get("company", ""),
                                    }
                                    for m in matches
                                ],
                            )
                        )
                        idx += match_len
                        continue

                detected.append(
                    DetectedEntity(
                        start=idx,
                        end=idx + match_len,
                        original_text=original,
                        canonical=canonical,
                        entity_type="PERSON",
                        match_type=(
                            "exact"
                            if is_exact
                            else ("first_name" if is_first_name else "variation")
                        ),
                        confidence="high",
                        status="auto-matched",
                        dictionary_id=person["id"],
                        source="person",
                        role=person.get("role", ""),
                    )
                )
                idx += match_len

    # --- FUZZY MATCHING (Pass 3) ---
    matched_ranges = [(d.start, d.end) for d in detected]

    words = list(
        re.finditer(
            r"\b[A-ZÄÖÜ][a-zäöüß]+(?:\s+[A-ZÄÖÜ][a-zäöüß]+)?\b", text
        )
    )

    all_person_vars = []
    for person in persons:
        for v in _extract_variations(person.get("variations", [])):
            if len(v) >= 4:
                all_person_vars.append((v, person))

    all_term_vars = []
    for term in terms:
        for v in _extract_variations(term.get("variations", [])):
            if len(v) >= 4:
                all_term_vars.append((v, term))

    for match in words:
        word = match.group()
        w_start, w_end = match.start(), match.end()

        if word in GERMAN_STOPWORDS or word.lower() in GERMAN_STOPWORDS:
            continue
        # Require minimum 4 characters for fuzzy matching — shorter words
        # produce too many false positives (e.g. "Da" → "Dejan")
        if len(word) < 4:
            continue
        if any(w_start < me and w_end > ms for ms, me in matched_ranges):
            continue

        best_match = None
        best_distance = 3
        # Scale max distance by word length: short words need closer matches
        max_distance = 1 if len(word) < 6 else 2

        for var_text, person in all_person_vars:
            d = levenshtein_distance(word.lower(), var_text.lower())
            if (
                d <= max_distance
                and d < best_distance
                and word[0].lower() == var_text[0].lower()
            ):
                best_distance = d
                best_match = ("person", person, var_text)

        for var_text, term in all_term_vars:
            d = levenshtein_distance(word.lower(), var_text.lower())
            if (
                d <= max_distance
                and d < best_distance
                and word[0].lower() == var_text[0].lower()
            ):
                best_distance = d
                best_match = ("term", term, var_text)

        if best_match:
            source_type, entry, matched_var = best_match
            if source_type == "person":
                detected.append(
                    DetectedEntity(
                        start=w_start,
                        end=w_end,
                        original_text=word,
                        canonical=entry["canonical_name"],
                        entity_type="PERSON",
                        match_type="fuzzy",
                        confidence="medium",
                        status="suggested",
                        dictionary_id=entry["id"],
                        source="person",
                        role=entry.get("role", ""),
                    )
                )
            else:
                category = entry.get("category", "term")
                # Downgrade short fuzzy term matches without context
                confidence = "medium"
                if len(matched_var) < 7 and not _has_context_support(
                    text, w_start, w_end, category
                ):
                    confidence = "low"
                detected.append(
                    DetectedEntity(
                        start=w_start,
                        end=w_end,
                        original_text=word,
                        canonical=entry["canonical_term"],
                        entity_type=CATEGORY_TO_TYPE.get(category, "TERM"),
                        match_type="fuzzy",
                        confidence=confidence,
                        status="suggested",
                        dictionary_id=entry["id"],
                        source="term",
                    )
                )

    # --- DEDUPLICATE (keep longest match at each position) ---
    detected.sort(key=lambda d: (d.start, -(d.end - d.start)))
    deduped = []
    last_end = -1
    for d in detected:
        if d.start >= last_end:
            deduped.append(d)
            last_end = d.end
    return deduped
