"""Dictionary admin CRUD router — persons, terms, variations, vector store.

Thin pass-through wrappers over `db.*` (and `vector_store.*` for the two
vector-store routes) with no behavior beyond request/response shaping.
Relocated out of `main.py` by SRV-A5 in `docs/REVIEW-2026-07-04.md`; the
HTML admin page itself (`GET /admin`) stays in `main.py` since it renders
`templates` rather than acting as a CRUD pass-through.

Bearer-token auth applied via the router-level dependency (SEC-2).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

import db
import vector_store
from routers.auth import require_bearer

router = APIRouter(dependencies=[Depends(require_bearer)])


# ─── Persons CRUD ───────────────────────────────────────────────────


@router.put("/api/admin/persons/{person_id}")
async def admin_update_person(person_id: int, request: Request):
    body = await request.json()
    await db.update_person(
        person_id,
        first_name=body.get("first_name", ""),
        last_name=body.get("last_name", ""),
        role=body.get("role", ""),
        department=body.get("department", ""),
        company=body.get("company", ""),
        context=body.get("context", ""),
        status=body.get("status", "active"),
    )
    return {"status": "ok"}


@router.delete("/api/admin/persons/{person_id}")
async def admin_delete_person(person_id: int):
    await db.delete_person(person_id)
    return {"status": "ok"}


@router.post("/api/admin/persons")
async def admin_create_person(request: Request):
    body = await request.json()
    first = body.get("first_name", "").strip()
    last = body.get("last_name", "").strip()
    canonical = f"{first} {last}".strip()
    pid = await db.create_person(
        canonical_name=canonical,
        first_name=first,
        last_name=last,
        role=body.get("role", ""),
        company=body.get("company", ""),
        context=body.get("context", ""),
    )
    return {"status": "ok", "id": pid, "canonical_name": canonical}


@router.post("/api/admin/persons/{person_id}/variations")
async def admin_add_person_variation(person_id: int, request: Request):
    body = await request.json()
    await db.save_person_variation(
        person_id, body["text"], body.get("type", "asr_correction")
    )
    # Return the newly created variation's ID
    pool = await db.get_pool()
    row = await pool.fetchrow(
        "SELECT id FROM person_variations WHERE person_id = $1 AND variation = $2",
        person_id,
        body["text"],
    )
    return {"status": "ok", "id": row["id"] if row else None}


@router.delete("/api/admin/persons/{person_id}/variations/{variation_id}")
async def admin_delete_person_variation(person_id: int, variation_id: int):
    await db.delete_person_variation(variation_id)
    return {"status": "ok"}


# ─── Terms CRUD ─────────────────────────────────────────────────────


@router.put("/api/admin/terms/{term_id}")
async def admin_update_term(term_id: int, request: Request):
    body = await request.json()
    await db.update_term(
        term_id,
        canonical_term=body.get("canonical_term", ""),
        category=body.get("category", ""),
        context=body.get("context", ""),
        status=body.get("status", "active"),
    )
    return {"status": "ok"}


@router.delete("/api/admin/terms/{term_id}")
async def admin_delete_term(term_id: int):
    await db.delete_term(term_id)
    return {"status": "ok"}


@router.post("/api/admin/terms")
async def admin_create_term(request: Request):
    body = await request.json()
    name = body.get("canonical_term", "").strip()
    tid = await db.create_term(
        canonical_term=name,
        category=body.get("category", "term"),
        context=body.get("context", ""),
    )
    return {"status": "ok", "id": tid, "canonical_term": name}


@router.post("/api/admin/terms/{term_id}/variations")
async def admin_add_term_variation(term_id: int, request: Request):
    body = await request.json()
    await db.save_term_variation(term_id, body["text"])
    pool = await db.get_pool()
    row = await pool.fetchrow(
        "SELECT id FROM term_variations WHERE term_id = $1 AND variation = $2",
        term_id,
        body["text"],
    )
    return {"status": "ok", "id": row["id"] if row else None}


@router.delete("/api/admin/terms/{term_id}/variations/{variation_id}")
async def admin_delete_term_variation(term_id: int, variation_id: int):
    await db.delete_term_variation(variation_id)
    return {"status": "ok"}


# ─── Vector Store Admin ─────────────────────────────────────────────


@router.get("/api/admin/vector-status")
async def vector_status():
    """Return Qdrant collection stats and connection status."""
    return await vector_store.get_collection_stats()


@router.post("/api/admin/backfill-vectors")
async def backfill_vectors(recreate: bool = False):
    """Backfill vector store from existing review_log and text_corrections.

    Args:
        recreate: If true, delete and recreate collections before backfill
                  (needed after embedding model/pooling changes).
    """
    if recreate:
        await vector_store.init_collections(recreate=True)
    pool = await db.get_pool()
    result = await vector_store.backfill_from_review_log(pool)
    return result
