"""
Bone content generator for LightRAG skeleton sync.

Each function generates (bone_id, content) tuples from database rows.
Content follows the ENTITY/TYPE/PROPERTIES/DESCRIPTION/ALIASES/RELATIONSHIP format
that LightRAG can extract entities and relationships from.
"""

import hashlib
import json
import re
from datetime import date, timedelta

import db


def slugify(name: str) -> str:
    """Lowercase, alphanumeric + hyphens."""
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def make_bone_id(category: str, name: str) -> str:
    """Generate a deterministic bone document ID."""
    return f"bone:{category}:{slugify(name)}"


def content_hash(content: str) -> str:
    """MD5 hash of generated bone content for change detection."""
    return hashlib.md5(content.strip().encode("utf-8")).hexdigest()


# ── Category mapping for org_units ──────────────────────────────────

ORG_TYPE_TO_CATEGORY = {
    "Organization": "org",
    "Team": "team",
    "StakeholderGroup": "stakeholder",
    "Product": "product",
    "Domain": "domain",
    "Capability": "capability",
}


# ── Person bones ────────────────────────────────────────────────────

async def generate_person_bone(pool, person_id: int):
    """Generate a single person bone. Returns (bone_id, content) or None."""
    row = await pool.fetchrow(
        "SELECT * FROM persons WHERE id = $1 AND status = 'active'", person_id
    )
    if not row:
        return None

    aliases = await pool.fetch(
        "SELECT variation FROM person_variations WHERE person_id = $1 AND approved = TRUE",
        person_id,
    )
    roles = await pool.fetch(
        """SELECT ra.role_name, ra.scope, o.name AS org_name
           FROM role_assignments ra
           LEFT JOIN org_units o ON ra.org_unit_id = o.id
           WHERE ra.person_id = $1 AND ra.status = 'active'""",
        person_id,
    )
    rels = await pool.fetch(
        """SELECT er.relationship_type, er.context,
                  er.target_type, er.target_id
           FROM entity_relationships er
           WHERE er.source_type = 'person' AND er.source_id = $1
                 AND er.status = 'active'""",
        person_id,
    )

    return await _build_person_bone(row, aliases, roles, rels, pool)


async def _build_person_bone(person, aliases, roles, rels, pool):
    name = person["canonical_name"]
    bid = make_bone_id("person", name)

    # Role descriptions
    role_parts = []
    for r in roles:
        org = r["org_name"] or ""
        scope = r["scope"] or ""
        if org and scope:
            role_parts.append(f'{r["role_name"]} bei {org}, verantwortlich für {scope}')
        elif org:
            role_parts.append(f'{r["role_name"]} bei {org}')
        else:
            role_parts.append(r["role_name"])

    # Fall back to persons.role if no role_assignments exist
    role_display = ", ".join(r["role_name"] for r in roles) if roles else (person["role"] or "")

    alias_list = [name] + [a["variation"] for a in aliases]

    props = {
        "role": role_display,
        "company": person["company"] or "",
        "department": person["department"] or "",
    }

    desc = name
    if role_parts:
        desc += " ist " + "; ".join(role_parts)
    elif person["role"]:
        company = f' bei {person["company"]}' if person["company"] else ""
        desc += f" ist {person['role']}{company}"
    desc += "."

    if person["context"]:
        desc += f" {person['context']}"

    content = f"""ENTITY: {name}
TYPE: Person
PROPERTIES: {json.dumps(props, ensure_ascii=False)}
DESCRIPTION: {desc}
ALIASES: {json.dumps(alias_list, ensure_ascii=False)}
"""

    # Relationships
    for rel in rels:
        target_name = await _resolve_entity_name(pool, rel["target_type"], rel["target_id"])
        ctx = rel["context"] or f"{name} {rel['relationship_type']} {target_name}"
        content += f"""
RELATIONSHIP: {name} --[{rel['relationship_type']}]--> {target_name}
CONTEXT: {ctx}
"""

    return (bid, content.strip())


async def generate_all_person_bones(pool):
    """Generate bones for all active persons."""
    rows = await pool.fetch("SELECT id FROM persons WHERE status = 'active'")
    results = []
    for row in rows:
        bone = await generate_person_bone(pool, row["id"])
        if bone:
            results.append(bone)
    return results


# ── Term bones ──────────────────────────────────────────────────────

async def generate_term_bone(pool, term_id: int):
    """Generate a single term bone."""
    row = await pool.fetchrow(
        "SELECT * FROM terms WHERE id = $1 AND status = 'active'", term_id
    )
    if not row:
        return None

    aliases = await pool.fetch(
        "SELECT variation FROM term_variations WHERE term_id = $1 AND approved = TRUE",
        term_id,
    )

    name = row["canonical_term"]
    bid = make_bone_id("term", name)

    alias_list = [name] + [a["variation"] for a in aliases]
    props = {"category": row["category"]}
    desc = row["context"] or f"{name} ({row['category']})"

    content = f"""ENTITY: {name}
TYPE: {row['category']}
PROPERTIES: {json.dumps(props, ensure_ascii=False)}
DESCRIPTION: {desc}
ALIASES: {json.dumps(alias_list, ensure_ascii=False)}
"""
    return (bid, content.strip())


async def generate_all_term_bones(pool):
    rows = await pool.fetch("SELECT id FROM terms WHERE status = 'active'")
    results = []
    for row in rows:
        bone = await generate_term_bone(pool, row["id"])
        if bone:
            results.append(bone)
    return results


# ── Org unit bones ──────────────────────────────────────────────────

async def generate_org_bone(pool, org_id: int):
    """Generate a single org unit bone."""
    row = await pool.fetchrow(
        "SELECT * FROM org_units WHERE id = $1 AND status = 'active'", org_id
    )
    if not row:
        return None

    category = ORG_TYPE_TO_CATEGORY.get(row["entity_type"], "org")
    bid = make_bone_id(category, row["name"])

    parent_name = None
    if row["parent_id"]:
        parent = await pool.fetchrow(
            "SELECT name FROM org_units WHERE id = $1", row["parent_id"]
        )
        if parent:
            parent_name = parent["name"]

    children = await pool.fetch(
        "SELECT name FROM org_units WHERE parent_id = $1 AND status = 'active'", org_id
    )

    props = row["properties"] or {}
    alias_list = [row["name"]] + (row["aliases"] or [])
    desc = row["description"] or f'{row["name"]} ({row["entity_type"]})'

    content = f"""ENTITY: {row['name']}
TYPE: {row['entity_type']}
PROPERTIES: {json.dumps(props, ensure_ascii=False)}
DESCRIPTION: {desc}
ALIASES: {json.dumps(alias_list, ensure_ascii=False)}
"""
    if parent_name:
        content += f"""
RELATIONSHIP: {row['name']} --[PART_OF]--> {parent_name}
CONTEXT: {row['name']} gehört zu {parent_name}
"""
    for child in children:
        content += f"""
RELATIONSHIP: {child['name']} --[PART_OF]--> {row['name']}
CONTEXT: {child['name']} gehört zu {row['name']}
"""

    return (bid, content.strip())


async def generate_all_org_bones(pool):
    rows = await pool.fetch("SELECT id FROM org_units WHERE status = 'active'")
    results = []
    for row in rows:
        bone = await generate_org_bone(pool, row["id"])
        if bone:
            results.append(bone)
    return results


# ── Initiative bones ────────────────────────────────────────────────

async def generate_initiative_bone(pool, init_id: int):
    row = await pool.fetchrow(
        "SELECT * FROM initiatives WHERE id = $1 AND status IN ('active', 'paused')",
        init_id,
    )
    if not row:
        return None

    bid = make_bone_id("initiative", row["name"])
    alias_list = [row["name"]] + (row["aliases"] or [])
    props = row["properties"] or {}
    desc = row["description"] or f'{row["name"]} ({row["initiative_type"]})'

    owner_name = None
    if row["owner_person_id"]:
        owner = await pool.fetchrow(
            "SELECT canonical_name FROM persons WHERE id = $1",
            row["owner_person_id"],
        )
        if owner:
            owner_name = owner["canonical_name"]

    content = f"""ENTITY: {row['name']}
TYPE: {row['initiative_type']}
PROPERTIES: {json.dumps(props, ensure_ascii=False)}
DESCRIPTION: {desc}
ALIASES: {json.dumps(alias_list, ensure_ascii=False)}
"""
    if owner_name:
        content += f"""
RELATIONSHIP: {owner_name} --[OWNS]--> {row['name']}
CONTEXT: {owner_name} ist verantwortlich für {row['name']}
"""

    return (bid, content.strip())


async def generate_all_initiative_bones(pool):
    rows = await pool.fetch(
        "SELECT id FROM initiatives WHERE status IN ('active', 'paused')"
    )
    results = []
    for row in rows:
        bone = await generate_initiative_bone(pool, row["id"])
        if bone:
            results.append(bone)
    return results


# ── Static entity bones ─────────────────────────────────────────────

async def generate_static_bone(pool, entity_id: int):
    row = await pool.fetchrow(
        "SELECT * FROM static_entities WHERE id = $1 AND status = 'active'",
        entity_id,
    )
    if not row:
        return None

    bid = make_bone_id("static", row["name"])
    alias_list = [row["name"]] + (row["aliases"] or [])
    props = row["properties"] or {}
    desc = row["description"] or row["name"]

    content = f"""ENTITY: {row['name']}
TYPE: {row['entity_type']}
PROPERTIES: {json.dumps(props, ensure_ascii=False)}
DESCRIPTION: {desc}
ALIASES: {json.dumps(alias_list, ensure_ascii=False)}
"""
    # Status transitions
    transitions = props.get("transitions_to", [])
    for target in transitions:
        content += f"""
RELATIONSHIP: {row['name']} --[TRANSITIONS_TO]--> Status-{target}
CONTEXT: Statusübergang von {row['name']} nach {target}
"""

    return (bid, content.strip())


async def generate_all_static_bones(pool):
    rows = await pool.fetch(
        "SELECT id FROM static_entities WHERE status = 'active'"
    )
    results = []
    for row in rows:
        bone = await generate_static_bone(pool, row["id"])
        if bone:
            results.append(bone)
    return results


# ── Temporal bones ──────────────────────────────────────────────────

MONTH_NAMES_DE = [
    "Januar", "Februar", "März", "April", "Mai", "Juni",
    "Juli", "August", "September", "Oktober", "November", "Dezember",
]
WEEKDAY_NAMES_DE = [
    "Montag", "Dienstag", "Mittwoch", "Donnerstag",
    "Freitag", "Samstag", "Sonntag",
]

# Fixed start of the temporal spine
TEMPORAL_START = date(2025, 1, 1)
# How far ahead of today the spine should reach
TEMPORAL_LOOKAHEAD_MONTHS = 6


def _end_of_month(year: int, month: int) -> date:
    """Last day of the given month."""
    if month == 12:
        return date(year, 12, 31)
    return date(year, month + 1, 1) - timedelta(days=1)


def _iso_week_start(iso_year: int, iso_week: int) -> date:
    """Monday of the given ISO week."""
    jan4 = date(iso_year, 1, 4)
    start_of_w1 = jan4 - timedelta(days=jan4.weekday())
    return start_of_w1 + timedelta(weeks=iso_week - 1)


def _generate_temporal_range(start_date: date, end_date: date):
    """
    Generate quarter, month, week, and day bones covering [start_date, end_date].
    Hierarchy: Quarter > Month > Week > Day
    Returns list of (bone_id, content) tuples.
    """
    results = []

    # --- Quarters ---
    sy, sq = start_date.year, (start_date.month - 1) // 3 + 1
    ey, eq = end_date.year, (end_date.month - 1) // 3 + 1

    year, q = sy, sq
    while (year, q) <= (ey, eq):
        month_start = (q - 1) * 3 + 1
        q_start = date(year, month_start, 1)
        q_end = _end_of_month(year, month_start + 2)

        identifier = f"{year}-Q{q}"
        bid = make_bone_id("temporal", identifier)
        iso_w_start = q_start.isocalendar()[1]
        iso_w_end = q_end.isocalendar()[1]

        content = f"""ENTITY: {identifier}
TYPE: Quarter
PROPERTIES: {json.dumps({"start_date": str(q_start), "end_date": str(q_end)})}
DESCRIPTION: Quartal {identifier} ({q_start} bis {q_end}), KW {iso_w_start}–{iso_w_end}
ALIASES: ["{identifier}", "Q{q} {year}"]"""
        results.append((bid, content.strip()))

        q += 1
        if q > 4:
            q = 1
            year += 1

    # --- Months ---
    year, month = start_date.year, start_date.month
    while date(year, month, 1) <= end_date:
        m_start = date(year, month, 1)
        m_end = _end_of_month(year, month)
        quarter = (month - 1) // 3 + 1
        month_name = MONTH_NAMES_DE[month - 1]

        identifier = f"{year}-{month:02d}"
        bid = make_bone_id("temporal", identifier)
        iso_w_start = m_start.isocalendar()[1]
        iso_w_end = m_end.isocalendar()[1]

        content = f"""ENTITY: {month_name} {year}
TYPE: Monat
PROPERTIES: {json.dumps({"start_date": str(m_start), "end_date": str(m_end), "quarter": f"{year}-Q{quarter}"})}
DESCRIPTION: {month_name} {year} ({m_start} bis {m_end}), KW {iso_w_start}–{iso_w_end}
ALIASES: ["{month_name} {year}", "{identifier}", "{month:02d}/{year}"]

RELATIONSHIP: {month_name} {year} --[PART_OF]--> {year}-Q{quarter}
CONTEXT: {month_name} {year} gehört zu Quartal {year}-Q{quarter}"""
        results.append((bid, content.strip()))

        month += 1
        if month > 12:
            month = 1
            year += 1

    # --- ISO Weeks ---
    seen_weeks = set()
    d = start_date
    while d <= end_date:
        iso_year, iso_week, _ = d.isocalendar()
        key = (iso_year, iso_week)
        if key not in seen_weeks:
            seen_weeks.add(key)
            w_start = _iso_week_start(iso_year, iso_week)
            w_end = w_start + timedelta(days=6)
            w_month = w_start.month
            w_quarter = (w_month - 1) // 3 + 1
            month_name = MONTH_NAMES_DE[w_month - 1]

            identifier = f"{iso_year}-KW{iso_week:02d}"
            bid = make_bone_id("temporal", identifier)

            content = f"""ENTITY: KW {iso_week} {iso_year}
TYPE: Woche
PROPERTIES: {json.dumps({"start_date": str(w_start), "end_date": str(w_end), "iso_week": iso_week, "iso_year": iso_year})}
DESCRIPTION: Kalenderwoche {iso_week} {iso_year} ({w_start} bis {w_end})
ALIASES: ["KW {iso_week} {iso_year}", "KW{iso_week:02d}", "{identifier}", "Woche {iso_week}"]

RELATIONSHIP: KW {iso_week} {iso_year} --[PART_OF]--> {month_name} {w_start.year}
CONTEXT: KW {iso_week} gehört zu {month_name} {w_start.year}"""
            results.append((bid, content.strip()))
        d += timedelta(days=7)

    # --- Days ---
    d = start_date
    while d <= end_date:
        iso_year, iso_week, iso_day = d.isocalendar()
        weekday = WEEKDAY_NAMES_DE[d.weekday()]
        month_name = MONTH_NAMES_DE[d.month - 1]
        quarter = (d.month - 1) // 3 + 1

        identifier = str(d)  # 2025-01-15
        bid = make_bone_id("temporal", identifier)

        content = f"""ENTITY: {d.strftime('%d')}. {month_name} {d.year}
TYPE: Tag
PROPERTIES: {json.dumps({"date": str(d), "weekday": weekday, "iso_week": iso_week, "quarter": f"{d.year}-Q{quarter}"})}
DESCRIPTION: {weekday}, {d.strftime('%d')}. {month_name} {d.year} (KW {iso_week})
ALIASES: ["{identifier}", "{d.strftime('%d.%m.%Y')}", "{weekday} KW {iso_week}"]

RELATIONSHIP: {d.strftime('%d')}. {month_name} {d.year} --[PART_OF]--> KW {iso_week} {iso_year}
CONTEXT: {d.strftime('%d')}. {month_name} {d.year} gehört zu KW {iso_week} {iso_year}"""
        results.append((bid, content.strip()))
        d += timedelta(days=1)

    return results


async def generate_all_temporal_bones(_pool):
    """
    Generate temporal bones from TEMPORAL_START (2025-01-01)
    to today + 6 months. Covers quarters, months, ISO weeks, and days.
    Each sync run extends the horizon automatically.
    """
    today = date.today()
    end_month = today.month + TEMPORAL_LOOKAHEAD_MONTHS
    end_year = today.year + (end_month - 1) // 12
    end_month = ((end_month - 1) % 12) + 1
    end_date = _end_of_month(end_year, end_month)

    return _generate_temporal_range(TEMPORAL_START, end_date)


# ── Relationship cluster bones ──────────────────────────────────────

async def generate_all_rel_cluster_bones(pool):
    """
    Group entity_relationships by org unit into cluster bones.
    Person relationships are embedded in person bones, not here.
    """
    # Get all active relationships involving org units
    rels = await pool.fetch(
        """SELECT er.*,
                  CASE WHEN er.source_type = 'org_unit' THEN er.source_id
                       WHEN er.target_type = 'org_unit' THEN er.target_id
                  END AS cluster_org_id
           FROM entity_relationships er
           WHERE er.status = 'active'
                 AND er.source_type != 'person'
                 AND (er.source_type = 'org_unit' OR er.target_type = 'org_unit')"""
    )

    # Group by cluster org
    clusters = {}
    for rel in rels:
        org_id = rel["cluster_org_id"]
        if org_id is None:
            continue
        if org_id not in clusters:
            clusters[org_id] = []
        clusters[org_id].append(rel)

    results = []
    for org_id, cluster_rels in clusters.items():
        org = await pool.fetchrow("SELECT name FROM org_units WHERE id = $1", org_id)
        if not org:
            continue

        org_name = org["name"]
        bid = make_bone_id("rel-cluster", f"{org_name}-rels")

        content = f"# Relationship Cluster: {org_name}\n\n"
        for rel in cluster_rels:
            src = await _resolve_entity_name(pool, rel["source_type"], rel["source_id"])
            tgt = await _resolve_entity_name(pool, rel["target_type"], rel["target_id"])
            ctx = rel["context"] or f"{src} {rel['relationship_type']} {tgt}"
            bidir = "yes" if rel["bidirectional"] else "no"
            content += f"""RELATIONSHIP: {src} --[{rel['relationship_type']}]--> {tgt}
CONTEXT: {ctx}
BIDIRECTIONAL: {bidir}

"""

        results.append((bid, content.strip()))

    return results


# ── Helpers ─────────────────────────────────────────────────────────

async def _resolve_entity_name(pool, entity_type: str, entity_id: int) -> str:
    """Look up the display name for a polymorphic entity reference."""
    table_map = {
        "person": ("persons", "canonical_name"),
        "org_unit": ("org_units", "name"),
        "term": ("terms", "canonical_term"),
        "initiative": ("initiatives", "name"),
        "static": ("static_entities", "name"),
    }
    entry = table_map.get(entity_type)
    if not entry:
        return f"Unknown({entity_type}:{entity_id})"
    table, col = entry
    row = await pool.fetchrow(
        f"SELECT {col} FROM {table} WHERE id = $1", entity_id
    )
    return row[col] if row else f"Unknown({entity_type}:{entity_id})"


# ── Main entry point ────────────────────────────────────────────────

async def generate_all_bones(pool=None):
    """
    Generate all bones from current database state.
    Returns list of (bone_id, content) tuples.
    """
    if pool is None:
        pool = await db.get_pool()

    generators = [
        generate_all_person_bones,
        generate_all_term_bones,
        generate_all_org_bones,
        generate_all_initiative_bones,
        generate_all_static_bones,
        generate_all_temporal_bones,
        generate_all_rel_cluster_bones,
    ]

    all_bones = []
    for gen in generators:
        bones = await gen(pool)
        all_bones.extend(bones)

    return all_bones
