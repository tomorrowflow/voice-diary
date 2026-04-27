"""
Skeleton sync engine — syncs bone documents to LightRAG.

Bones are individual LightRAG documents with deterministic IDs (bone:{category}:{slug}).
The engine uses content hashing to detect changes and only re-ingests when content differs.
"""

import asyncio
import logging
import time
from dataclasses import asdict, dataclass, field

import httpx

import bone_generator
import db
from document_processor import get_lightrag_api_key, get_lightrag_url, _lightrag_headers

logger = logging.getLogger(__name__)

# Prevent concurrent syncs
_sync_lock = asyncio.Lock()

# Limit parallel LightRAG calls
_lightrag_semaphore = asyncio.Semaphore(3)


@dataclass
class SyncStats:
    created: int = 0
    updated: int = 0
    deleted: int = 0
    unchanged: int = 0
    failed: int = 0
    errors: list = field(default_factory=list)

    def has_changes(self) -> bool:
        return self.created > 0 or self.updated > 0 or self.deleted > 0

    def to_dict(self) -> dict:
        return asdict(self)


# ── LightRAG HTTP helpers ───────────────────────────────────────────

async def _lightrag_insert(url: str, api_key: str, bone_id: str, content: str):
    """Insert a bone document into LightRAG with an explicit ID."""
    async with _lightrag_semaphore:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(
                f"{url}/documents/text",
                json={
                    "text": content,
                    "id": bone_id,
                    "file_source": bone_id,
                },
                headers=_lightrag_headers(api_key),
            )
            resp.raise_for_status()
            return resp.json()


async def _lightrag_delete(url: str, api_key: str, bone_id: str):
    """Delete a bone document from LightRAG by doc ID."""
    async with _lightrag_semaphore:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.request(
                "DELETE",
                f"{url}/documents/delete_document",
                json={"doc_ids": [bone_id]},
                headers=_lightrag_headers(api_key),
            )
            resp.raise_for_status()
            return resp.json()


# ── Sync state DB operations ───────────────────────────────────────

async def _get_all_sync_states(pool) -> dict:
    """Returns {bone_id: row} for all synced bones."""
    rows = await pool.fetch(
        "SELECT * FROM skeleton_sync_state WHERE sync_status = 'synced'"
    )
    return {r["bone_id"]: r for r in rows}


async def _upsert_sync_state(
    pool, bone_id: str, source_table: str, source_id: int,
    content_hash_val: str, content_text: str, status: str = "synced",
    error_message: str = None,
):
    await pool.execute(
        """INSERT INTO skeleton_sync_state
               (bone_id, source_table, source_id, content_hash, content_text,
                sync_status, last_synced_at, error_message)
           VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7)
           ON CONFLICT (bone_id) DO UPDATE SET
               source_table = $2, source_id = $3, content_hash = $4,
               content_text = $5, sync_status = $6, last_synced_at = NOW(),
               error_message = $7""",
        bone_id, source_table, source_id, content_hash_val, content_text,
        status, error_message,
    )


async def _mark_deleted(pool, bone_id: str):
    await pool.execute(
        """UPDATE skeleton_sync_state
           SET sync_status = 'deleted', last_synced_at = NOW()
           WHERE bone_id = $1""",
        bone_id,
    )


async def _log_sync_run(pool, mode: str, stats: SyncStats, triggered_by: str, duration_ms: int):
    status = "success"
    if stats.failed > 0 and stats.created + stats.updated + stats.deleted > 0:
        status = "partial"
    elif stats.failed > 0:
        status = "failed"

    error_details = "\n".join(stats.errors) if stats.errors else None

    await pool.execute(
        """INSERT INTO skeleton_sync_log
               (sync_mode, bones_created, bones_updated, bones_deleted,
                bones_unchanged, bones_failed, duration_ms, status,
                error_details, triggered_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)""",
        mode, stats.created, stats.updated, stats.deleted,
        stats.unchanged, stats.failed, duration_ms, status,
        error_details, triggered_by,
    )


# ── Source table / source_id inference ──────────────────────────────

def _infer_source(bone_id: str, category: str) -> tuple[str, int]:
    """
    Return (source_table, source_id) for a bone.
    For bones generated from tables, the source_id is looked up during sync.
    Returns placeholder (table, 0) — actual source_id set per bone.
    """
    table_map = {
        "person": "persons",
        "term": "terms",
        "org": "org_units", "team": "org_units", "stakeholder": "org_units",
        "product": "org_units", "domain": "org_units", "capability": "org_units",
        "initiative": "initiatives",
        "static": "static_entities",
        "temporal": "_generated",
        "rel-cluster": "entity_relationships",
    }
    return (table_map.get(category, "_unknown"), 0)


# ── Core sync logic ────────────────────────────────────────────────

async def sync_full(triggered_by: str = "manual", force: bool = False) -> SyncStats:
    """
    Full sync: regenerate all bones, compare hashes, update LightRAG.
    Only touches bone:* documents — diary:* documents are never affected.

    If force=True, deletes all existing bones from LightRAG first,
    clears sync state, and re-inserts everything fresh.
    """
    if force:
        pool = await db.get_pool()
        url = await get_lightrag_url()
        api_key = await get_lightrag_api_key()

        # Delete all existing bones from LightRAG
        existing_bones = await pool.fetch(
            "SELECT bone_id FROM skeleton_sync_state WHERE sync_status = 'synced'"
        )
        if existing_bones:
            bone_ids = [r["bone_id"] for r in existing_bones]
            logger.info("Force sync: deleting %d bones from LightRAG", len(bone_ids))
            try:
                # Batch delete — send all IDs at once
                async with httpx.AsyncClient(timeout=120.0) as client:
                    resp = await client.request(
                        "DELETE",
                        f"{url}/documents/delete_document",
                        json={"doc_ids": bone_ids},
                        headers=_lightrag_headers(api_key),
                    )
                    resp.raise_for_status()
            except Exception as e:
                logger.warning("Force sync: bulk delete failed, continuing: %s", e)

        # Clear sync state
        await pool.execute("DELETE FROM skeleton_sync_state")
        logger.info("Force sync: cleared skeleton_sync_state")

    async with _sync_lock:
        return await _sync_impl(mode="full", triggered_by=triggered_by)


async def sync_incremental(triggered_by: str = "manual") -> SyncStats:
    """
    Incremental sync: same as full but intended for frequent calls.
    Hash comparison means unchanged bones are skipped efficiently.
    """
    async with _sync_lock:
        return await _sync_impl(mode="incremental", triggered_by=triggered_by)


async def _sync_impl(mode: str, triggered_by: str) -> SyncStats:
    start = time.monotonic()
    stats = SyncStats()
    pool = await db.get_pool()
    url = await get_lightrag_url()
    api_key = await get_lightrag_api_key()

    # Generate all bones from current DB state
    all_bones = await bone_generator.generate_all_bones(pool)
    generated_ids = set()

    # Get existing sync states
    existing = await _get_all_sync_states(pool)

    for bid, content in all_bones:
        generated_ids.add(bid)
        chash = bone_generator.content_hash(content)

        # Parse category for source table
        parts = bid.split(":", 2)
        category = parts[1] if len(parts) >= 2 else "unknown"
        source_table, _ = _infer_source(bid, category)
        source_id = 0  # placeholder — not critical for sync logic

        ex = existing.get(bid)

        if ex and ex["content_hash"] == chash:
            stats.unchanged += 1
            continue

        try:
            if ex:
                # Changed — delete old, insert new
                await _lightrag_delete(url, api_key, bid)
                await _lightrag_insert(url, api_key, bid, content)
                stats.updated += 1
            else:
                # New bone
                await _lightrag_insert(url, api_key, bid, content)
                stats.created += 1

            await _upsert_sync_state(
                pool, bid, source_table, source_id, chash, content
            )
        except Exception as e:
            stats.failed += 1
            stats.errors.append(f"{bid}: {e}")
            logger.error("Sync failed for %s: %s", bid, e)
            await _upsert_sync_state(
                pool, bid, source_table, source_id, chash, content,
                status="failed", error_message=str(e),
            )

    # Clean up orphaned bones (in sync_state but no longer generated)
    if mode == "full":
        orphan_ids = set(existing.keys()) - generated_ids
        for bid in orphan_ids:
            try:
                await _lightrag_delete(url, api_key, bid)
                await _mark_deleted(pool, bid)
                stats.deleted += 1
            except Exception as e:
                stats.failed += 1
                stats.errors.append(f"delete {bid}: {e}")
                logger.error("Orphan delete failed for %s: %s", bid, e)

    duration_ms = int((time.monotonic() - start) * 1000)
    await _log_sync_run(pool, mode, stats, triggered_by, duration_ms)

    logger.info(
        "Skeleton sync (%s, triggered_by=%s): created=%d updated=%d deleted=%d "
        "unchanged=%d failed=%d [%dms]",
        mode, triggered_by, stats.created, stats.updated, stats.deleted,
        stats.unchanged, stats.failed, duration_ms,
    )

    return stats


async def sync_single_bone(target_bone_id: str) -> str:
    """Sync a single bone. Returns 'created', 'updated', 'unchanged', or 'deleted'."""
    pool = await db.get_pool()
    url = await get_lightrag_url()
    api_key = await get_lightrag_api_key()

    # Generate all bones and find the target
    all_bones = await bone_generator.generate_all_bones(pool)
    bone_map = dict(all_bones)

    content = bone_map.get(target_bone_id)

    if content is None:
        # Source record was deleted or deactivated
        try:
            await _lightrag_delete(url, api_key, target_bone_id)
        except Exception:
            pass
        await _mark_deleted(pool, target_bone_id)
        return "deleted"

    chash = bone_generator.content_hash(content)
    existing = await pool.fetchrow(
        "SELECT * FROM skeleton_sync_state WHERE bone_id = $1",
        target_bone_id,
    )

    if existing and existing["content_hash"] == chash:
        return "unchanged"

    if existing:
        await _lightrag_delete(url, api_key, target_bone_id)

    await _lightrag_insert(url, api_key, target_bone_id, content)

    parts = target_bone_id.split(":", 2)
    category = parts[1] if len(parts) >= 2 else "unknown"
    source_table, source_id = _infer_source(target_bone_id, category)

    await _upsert_sync_state(
        pool, target_bone_id, source_table, source_id, chash, content
    )

    result = "updated" if existing else "created"

    # Log single sync
    s = SyncStats()
    setattr(s, "created" if result == "created" else "updated", 1)
    await _log_sync_run(pool, "single", s, f"single:{target_bone_id}", 0)

    return result


# ── Query functions ─────────────────────────────────────────────────

async def get_sync_status() -> dict:
    """Current sync state overview."""
    pool = await db.get_pool()

    counts = await pool.fetch(
        """SELECT sync_status, COUNT(*) AS cnt
           FROM skeleton_sync_state
           GROUP BY sync_status"""
    )
    status_counts = {r["sync_status"]: r["cnt"] for r in counts}

    last_log = await pool.fetchrow(
        "SELECT * FROM skeleton_sync_log ORDER BY created_at DESC LIMIT 1"
    )

    total = sum(status_counts.values())

    return {
        "total_bones": total,
        "synced": status_counts.get("synced", 0),
        "pending": status_counts.get("pending", 0),
        "failed": status_counts.get("failed", 0),
        "deleted": status_counts.get("deleted", 0),
        "last_sync": dict(last_log) if last_log else None,
    }


async def get_sync_diff() -> dict:
    """
    Dry-run: generate all bones, compare against stored state,
    report what would change without actually syncing.
    """
    pool = await db.get_pool()
    all_bones = await bone_generator.generate_all_bones(pool)
    existing = await _get_all_sync_states(pool)

    new = []
    changed = []
    unchanged_count = 0
    deleted = []

    generated_ids = set()
    for bid, content in all_bones:
        generated_ids.add(bid)
        chash = bone_generator.content_hash(content)
        ex = existing.get(bid)

        if ex is None:
            new.append({"bone_id": bid})
        elif ex["content_hash"] != chash:
            changed.append({"bone_id": bid, "old_hash": ex["content_hash"], "new_hash": chash})
        else:
            unchanged_count += 1

    for bid in set(existing.keys()) - generated_ids:
        deleted.append({"bone_id": bid})

    return {
        "new": new,
        "changed": changed,
        "deleted": deleted,
        "unchanged": unchanged_count,
    }


async def render_bone(target_bone_id: str) -> str | None:
    """Generate and return bone content without syncing."""
    pool = await db.get_pool()
    all_bones = await bone_generator.generate_all_bones(pool)
    bone_map = dict(all_bones)
    return bone_map.get(target_bone_id)


async def list_bones() -> list[dict]:
    """List all bones in sync state."""
    pool = await db.get_pool()
    rows = await pool.fetch(
        """SELECT bone_id, source_table, content_hash, sync_status,
                  last_synced_at, error_message
           FROM skeleton_sync_state
           ORDER BY bone_id"""
    )
    return [dict(r) for r in rows]


async def get_sync_log(limit: int = 20) -> list[dict]:
    """Recent sync log entries."""
    pool = await db.get_pool()
    rows = await pool.fetch(
        "SELECT * FROM skeleton_sync_log ORDER BY created_at DESC LIMIT $1",
        limit,
    )
    return [dict(r) for r in rows]
