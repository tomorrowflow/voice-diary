"""
Qdrant vector store for contextual learning.

Stores past correction contexts and entity usage samples as embeddings,
enabling few-shot examples to be injected into LLM prompts for transcript
correction and entity validation.

Uses fastembed (paraphrase-multilingual-MiniLM-L12-v2, 384-dim) for embeddings —
runs on CPU, no external service needed.
"""

import logging
import os
import re
import uuid
import warnings
from datetime import date as date_type

from dotenv import load_dotenv
from pathlib import Path

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

logger = logging.getLogger(__name__)

QDRANT_URL = os.getenv("QDRANT_URL", "http://qdrant:6333")
VECTOR_SEARCH_ENABLED = os.getenv("VECTOR_SEARCH_ENABLED", "false").lower() == "true"
EMBEDDING_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

COLLECTION_CORRECTIONS = "correction_contexts"
COLLECTION_ENTITIES = "entity_samples"

_client = None


async def _get_client():
    """Lazy-init Qdrant client with fastembed integration."""
    global _client
    if _client is None:
        from qdrant_client import QdrantClient

        _client = QdrantClient(
            url=QDRANT_URL,
            timeout=10,
        )
        # Suppress pooling-change warning — we use mean pooling going forward
        with warnings.catch_warnings():
            warnings.filterwarnings("ignore", message=".*now uses mean pooling.*")
            _client.set_model(EMBEDDING_MODEL)
        logger.info("Qdrant client connected to %s", QDRANT_URL)
    return _client


async def init_collections(recreate: bool = False):
    """Create collections if they don't exist. Called from app lifespan.

    Args:
        recreate: If True, delete and recreate existing collections
                  (e.g. after embedding model/pooling changes).
    """
    if not VECTOR_SEARCH_ENABLED:
        return

    try:
        client = await _get_client()
        existing = {c.name for c in client.get_collections().collections}

        for name in (COLLECTION_CORRECTIONS, COLLECTION_ENTITIES):
            if recreate and name in existing:
                client.delete_collection(collection_name=name)
                logger.info("Deleted collection for reindex: %s", name)
                existing.discard(name)

            if name not in existing:
                client.create_collection(
                    collection_name=name,
                    vectors_config=client.get_fastembed_vector_params(),
                )
                logger.info("Created collection: %s", name)
            else:
                logger.info("Collection exists: %s", name)

    except Exception as e:
        logger.warning("Failed to init Qdrant collections: %s", e)


async def close():
    """Close Qdrant client. Called from app lifespan shutdown."""
    global _client
    if _client is not None:
        try:
            _client.close()
        except Exception:
            pass
        _client = None


async def delete_transcript_vectors(transcript_id: int):
    """Delete all vectors for a given transcript from both collections.

    Called before re-inserting to prevent duplicates on resubmit.
    """
    if not VECTOR_SEARCH_ENABLED:
        return

    try:
        from qdrant_client.models import FieldCondition, Filter, MatchValue

        client = await _get_client()
        tid_filter = Filter(
            must=[
                FieldCondition(
                    key="transcript_id",
                    match=MatchValue(value=transcript_id),
                )
            ]
        )
        for collection in (COLLECTION_CORRECTIONS, COLLECTION_ENTITIES):
            client.delete(
                collection_name=collection,
                points_selector=tid_filter,
            )
        logger.info(
            "Deleted existing vectors for transcript %s", transcript_id
        )
    except Exception as e:
        logger.warning(
            "Failed to delete vectors for transcript %s: %s",
            transcript_id,
            e,
        )


def _extract_context_window(text: str, start: int, end: int, window: int = 50) -> dict:
    """Extract a context window around a position in text."""
    ctx_start = max(0, start - window)
    ctx_end = min(len(text), end + window)
    return {
        "context_before": text[ctx_start:start],
        "context_after": text[end:ctx_end],
        "full_context": text[ctx_start:ctx_end],
    }


def _find_sentence(text: str, start: int, end: int) -> str:
    """Extract the sentence containing the given span."""
    # Find sentence boundaries (., !, ?, or newline)
    sent_start = start
    while sent_start > 0 and text[sent_start - 1] not in ".!?\n":
        sent_start -= 1

    sent_end = end
    while sent_end < len(text) and text[sent_end] not in ".!?\n":
        sent_end += 1

    sentence = text[sent_start:sent_end].strip()
    return sentence if sentence else text[max(0, start - 80) : min(len(text), end + 80)]


async def store_correction_context(
    original_text: str,
    corrected_text: str,
    full_text: str,
    start: int,
    end: int,
    correction_type: str,
    transcript_id: int,
    transcript_date: str,
):
    """Store a text correction with its surrounding context."""
    if not VECTOR_SEARCH_ENABLED:
        return

    try:
        client = await _get_client()
        ctx = _extract_context_window(full_text, start, end)

        # The embedded document: context window with the correction site marked
        embed_text = (
            f"{ctx['context_before']}[{original_text} -> {corrected_text}]"
            f"{ctx['context_after']}"
        )

        client.add(
            collection_name=COLLECTION_CORRECTIONS,
            documents=[embed_text],
            metadata=[
                {
                    "original_text": original_text,
                    "corrected_text": corrected_text,
                    "context_before": ctx["context_before"],
                    "context_after": ctx["context_after"],
                    "full_context": ctx["full_context"],
                    "correction_type": correction_type,
                    "transcript_id": transcript_id,
                    "transcript_date": transcript_date,
                }
            ],
            ids=[str(uuid.uuid4())],
        )
        logger.debug(
            "Stored correction context: '%s' -> '%s'", original_text, corrected_text
        )
    except Exception as e:
        logger.warning("Failed to store correction context: %s", e)


async def store_entity_sample(
    entity_canonical: str,
    entity_type: str,
    entity_id: int | None,
    source: str,
    original_text: str,
    full_text: str,
    start: int,
    end: int,
    match_type: str,
    action: str,
    transcript_id: int,
    transcript_date: str,
):
    """Store a confirmed entity usage with its sentence context."""
    if not VECTOR_SEARCH_ENABLED:
        return

    try:
        client = await _get_client()
        sentence = _find_sentence(full_text, start, end)

        # Embed the sentence containing the entity
        embed_text = sentence

        client.add(
            collection_name=COLLECTION_ENTITIES,
            documents=[embed_text],
            metadata=[
                {
                    "entity_canonical": entity_canonical,
                    "entity_type": entity_type,
                    "entity_id": entity_id or 0,
                    "source": source,
                    "original_text": original_text,
                    "sentence": sentence,
                    "match_type": match_type,
                    "action": action,
                    "transcript_id": transcript_id,
                    "transcript_date": transcript_date,
                }
            ],
            ids=[str(uuid.uuid4())],
        )
        logger.debug("Stored entity sample: '%s' (%s)", entity_canonical, entity_type)
    except Exception as e:
        logger.warning("Failed to store entity sample: %s", e)


async def find_similar_corrections(
    text: str, limit: int = 5, threshold: float = 0.65
) -> list[dict]:
    """Query for past corrections in similar contexts.

    Returns list of {original_text, corrected_text, context_before, context_after, score}.
    """
    if not VECTOR_SEARCH_ENABLED:
        return []

    try:
        client = await _get_client()
        results = client.query(
            collection_name=COLLECTION_CORRECTIONS,
            query_text=text,
            limit=limit,
        )

        corrections = []
        for hit in results:
            if hit.score < threshold:
                continue
            meta = hit.metadata
            corrections.append(
                {
                    "original_text": meta.get("original_text", ""),
                    "corrected_text": meta.get("corrected_text", ""),
                    "context_before": meta.get("context_before", ""),
                    "context_after": meta.get("context_after", ""),
                    "full_context": meta.get("full_context", ""),
                    "correction_type": meta.get("correction_type", ""),
                    "score": hit.score,
                }
            )
        return corrections
    except Exception as e:
        logger.warning("Failed to query similar corrections: %s", e)
        return []


async def find_entity_usage_samples(
    canonical: str,
    entity_type: str,
    context: str = "",
    limit: int = 5,
    threshold: float = 0.6,
) -> list[dict]:
    """Query for past usage samples of a specific entity.

    Uses the context text for semantic similarity, filtered by entity name and type.
    Returns list of {entity_canonical, sentence, match_type, action, score}.
    """
    if not VECTOR_SEARCH_ENABLED:
        return []

    try:
        from qdrant_client.models import FieldCondition, Filter, MatchValue

        client = await _get_client()

        # Build filter for entity canonical name and type
        query_filter = Filter(
            must=[
                FieldCondition(
                    key="entity_canonical",
                    match=MatchValue(value=canonical),
                ),
                FieldCondition(
                    key="entity_type",
                    match=MatchValue(value=entity_type),
                ),
            ]
        )

        # Use context if provided, otherwise fall back to canonical name
        query_text = context if context else canonical

        results = client.query(
            collection_name=COLLECTION_ENTITIES,
            query_text=query_text,
            query_filter=query_filter,
            limit=limit,
        )

        samples = []
        for hit in results:
            if hit.score < threshold:
                continue
            meta = hit.metadata
            samples.append(
                {
                    "entity_canonical": meta.get("entity_canonical", ""),
                    "entity_type": meta.get("entity_type", ""),
                    "sentence": meta.get("sentence", ""),
                    "original_text": meta.get("original_text", ""),
                    "match_type": meta.get("match_type", ""),
                    "action": meta.get("action", ""),
                    "score": hit.score,
                }
            )
        return samples
    except Exception as e:
        logger.warning("Failed to query entity usage samples: %s", e)
        return []


async def get_collection_stats() -> dict:
    """Return collection point counts and connection status."""
    if not VECTOR_SEARCH_ENABLED:
        return {"enabled": False}

    try:
        client = await _get_client()
        corrections_info = client.get_collection(COLLECTION_CORRECTIONS)
        entities_info = client.get_collection(COLLECTION_ENTITIES)
        return {
            "enabled": True,
            "connected": True,
            "corrections_count": corrections_info.points_count,
            "entities_count": entities_info.points_count,
        }
    except Exception as e:
        return {
            "enabled": True,
            "connected": False,
            "error": str(e),
        }


async def backfill_from_review_log(pool):
    """One-time import from existing review_log + transcripts.

    Reads all past confirmed/corrected entities from review_log,
    extracts context from corrected_text, and stores in both collections.
    """
    if not VECTOR_SEARCH_ENABLED:
        return {"status": "disabled"}

    try:
        # Fetch review log entries with transcript text
        rows = await pool.fetch("""
            SELECT
                rl.transcript_id,
                rl.original_text,
                rl.corrected_text,
                rl.entity_type,
                rl.match_type,
                rl.action,
                rl.created_at,
                t.corrected_text,
                t.raw_text,
                t.date as transcript_date
            FROM review_log rl
            JOIN transcripts t ON t.id = rl.transcript_id
            WHERE rl.action IN ('confirmed', 'corrected')
            ORDER BY rl.created_at
        """)

        stored_corrections = 0
        stored_entities = 0

        for row in rows:
            full_text = row["corrected_text"] or row["raw_text"] or ""
            if not full_text:
                continue

            transcript_date = (
                row["transcript_date"].isoformat()
                if row["transcript_date"]
                else ""
            )

            # Find the entity text in the transcript
            original = row["original_text"]
            canonical = row["corrected_text"]
            match = re.search(re.escape(original), full_text, re.IGNORECASE)
            if not match:
                # Try canonical
                match = re.search(re.escape(canonical), full_text, re.IGNORECASE)
            if not match:
                continue

            start, end = match.start(), match.end()

            # Store as entity sample
            await store_entity_sample(
                entity_canonical=canonical,
                entity_type=row["entity_type"],
                entity_id=None,
                source="backfill",
                original_text=original,
                full_text=full_text,
                start=start,
                end=end,
                match_type=row["match_type"],
                action=row["action"],
                transcript_id=row["transcript_id"],
                transcript_date=transcript_date,
            )
            stored_entities += 1

            # If it was a correction (original != canonical), also store as correction context
            if row["action"] == "corrected" and original.lower() != canonical.lower():
                await store_correction_context(
                    original_text=original,
                    corrected_text=canonical,
                    full_text=full_text,
                    start=start,
                    end=end,
                    correction_type="entity_correction",
                    transcript_id=row["transcript_id"],
                    transcript_date=transcript_date,
                )
                stored_corrections += 1

        # Also backfill text_corrections
        text_corr_rows = await pool.fetch("""
            SELECT
                tc.original_text,
                tc.corrected_text,
                tc.correction_type,
                tc.created_at
            FROM text_corrections tc
            WHERE tc.correction_type = 'word'
        """)

        for tc_row in text_corr_rows:
            # Text corrections don't have position info; store with minimal context
            await store_correction_context(
                original_text=tc_row["original_text"],
                corrected_text=tc_row["corrected_text"],
                full_text=tc_row["original_text"],
                start=0,
                end=len(tc_row["original_text"]),
                correction_type="text_correction",
                transcript_id=0,
                transcript_date="",
            )
            stored_corrections += 1

        logger.info(
            "Backfill complete: %d correction contexts, %d entity samples",
            stored_corrections,
            stored_entities,
        )
        return {
            "status": "ok",
            "corrections_stored": stored_corrections,
            "entities_stored": stored_entities,
            "review_log_rows": len(rows),
            "text_correction_rows": len(text_corr_rows),
        }

    except Exception as e:
        logger.error("Backfill failed: %s", e)
        return {"status": "error", "error": str(e)}
