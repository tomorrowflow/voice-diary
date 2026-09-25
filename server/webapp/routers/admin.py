"""Skeleton entity admin CRUD router — org units, relationships, role
assignments, static entities, initiatives.

Thin pass-through wrappers over `db.*` with no behavior beyond request/
response shaping. Relocated out of `main.py` by SRV-A5 in
`docs/REVIEW-2026-07-04.md`.

Bearer-token auth applied via the router-level dependency (SEC-2).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

import db
from routers.auth import require_bearer

router = APIRouter(dependencies=[Depends(require_bearer)])


# ─── Org Units CRUD ────────────────────────────────────────────────


@router.get("/api/admin/org-units")
async def admin_list_org_units():
    return await db.list_org_units()


@router.post("/api/admin/org-units")
async def admin_create_org_unit(request: Request):
    body = await request.json()
    oid = await db.create_org_unit(
        name=body["name"],
        entity_type=body["entity_type"],
        parent_id=body.get("parent_id"),
        description=body.get("description", ""),
        properties=body.get("properties"),
        aliases=body.get("aliases", []),
    )
    return {"status": "ok", "id": oid}


@router.put("/api/admin/org-units/{org_id}")
async def admin_update_org_unit(org_id: int, request: Request):
    body = await request.json()
    await db.update_org_unit(org_id, **body)
    return {"status": "ok"}


@router.delete("/api/admin/org-units/{org_id}")
async def admin_delete_org_unit(org_id: int):
    await db.delete_org_unit(org_id)
    return {"status": "ok"}


# ─── Entity Relationships CRUD ─────────────────────────────────────


@router.get("/api/admin/relationships")
async def admin_list_relationships():
    return await db.list_entity_relationships()


@router.post("/api/admin/relationships")
async def admin_create_relationship(request: Request):
    body = await request.json()
    rid = await db.create_entity_relationship(
        source_type=body["source_type"],
        source_id=body["source_id"],
        relationship_type=body["relationship_type"],
        target_type=body["target_type"],
        target_id=body["target_id"],
        context=body.get("context", ""),
        bidirectional=body.get("bidirectional", False),
    )
    return {"status": "ok", "id": rid}


@router.delete("/api/admin/relationships/{rel_id}")
async def admin_delete_relationship(rel_id: int):
    await db.delete_entity_relationship(rel_id)
    return {"status": "ok"}


# ─── Role Assignments CRUD ─────────────────────────────────────────


@router.get("/api/admin/role-assignments")
async def admin_list_role_assignments(person_id: int = None):
    return await db.list_role_assignments(person_id)


@router.post("/api/admin/role-assignments")
async def admin_create_role_assignment(request: Request):
    body = await request.json()
    rid = await db.create_role_assignment(
        person_id=body["person_id"],
        role_name=body["role_name"],
        org_unit_id=body.get("org_unit_id"),
        scope=body.get("scope", ""),
        role_entity_name=body.get("role_entity_name"),
        start_date=body.get("start_date"),
        end_date=body.get("end_date"),
    )
    return {"status": "ok", "id": rid}


@router.put("/api/admin/role-assignments/{ra_id}")
async def admin_update_role_assignment(ra_id: int, request: Request):
    body = await request.json()
    await db.update_role_assignment(ra_id, **body)
    return {"status": "ok"}


@router.delete("/api/admin/role-assignments/{ra_id}")
async def admin_delete_role_assignment(ra_id: int):
    await db.delete_role_assignment(ra_id)
    return {"status": "ok"}


# ─── Static Entities CRUD ──────────────────────────────────────────


@router.get("/api/admin/static-entities")
async def admin_list_static_entities():
    return await db.list_static_entities()


@router.post("/api/admin/static-entities")
async def admin_create_static_entity(request: Request):
    body = await request.json()
    sid = await db.create_static_entity(
        name=body["name"],
        entity_type=body["entity_type"],
        description=body.get("description", ""),
        properties=body.get("properties"),
        aliases=body.get("aliases", []),
    )
    return {"status": "ok", "id": sid}


@router.put("/api/admin/static-entities/{entity_id}")
async def admin_update_static_entity(entity_id: int, request: Request):
    body = await request.json()
    await db.update_static_entity(entity_id, **body)
    return {"status": "ok"}


@router.delete("/api/admin/static-entities/{entity_id}")
async def admin_delete_static_entity(entity_id: int):
    await db.delete_static_entity(entity_id)
    return {"status": "ok"}


# ─── Initiatives CRUD ──────────────────────────────────────────────


@router.get("/api/admin/initiatives")
async def admin_list_initiatives():
    return await db.list_initiatives()


@router.post("/api/admin/initiatives")
async def admin_create_initiative(request: Request):
    body = await request.json()
    iid = await db.create_initiative(
        name=body["name"],
        initiative_type=body["initiative_type"],
        description=body.get("description", ""),
        properties=body.get("properties"),
        aliases=body.get("aliases", []),
        owner_person_id=body.get("owner_person_id"),
    )
    return {"status": "ok", "id": iid}


@router.put("/api/admin/initiatives/{init_id}")
async def admin_update_initiative(init_id: int, request: Request):
    body = await request.json()
    await db.update_initiative(init_id, **body)
    return {"status": "ok"}


@router.delete("/api/admin/initiatives/{init_id}")
async def admin_delete_initiative(init_id: int):
    await db.delete_initiative(init_id)
    return {"status": "ok"}
