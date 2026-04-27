# LIGHTRAG SKELETON SYNC — Specification for Claude Code

> **For Claude Code**: This spec describes a sync system between a PostgreSQL-backed
> preprocessing app and a LightRAG knowledge graph. The actual app repository is
> available for you to review. Where this spec makes assumptions about the existing
> app structure (database schema, module layout, API patterns), these are marked with
> `[ASSUMPTION]`. Please verify these against the actual codebase and flag any
> discrepancies before implementing.

---

## 1. Problem Statement

The CTO Knowledge Base uses LightRAG as its graph-based RAG system. The knowledge
base is fed by voice diary entries that go through a preprocessing pipeline. That
pipeline is built as a **Python app backed by PostgreSQL** — it maintains a dictionary
of known entities (people, companies, terms, org structure) which is used to normalize
transcriptions before ingestion into LightRAG.

Currently, structural/skeleton data (who works where, what teams exist, what the org
hierarchy looks like) must be manually maintained as static markdown files and ingested
into LightRAG once. This is brittle — when something changes in the dictionary app
(new hire, role change, org restructure), the LightRAG graph drifts out of sync.

### Goal

Build a sync layer that:
1. Reads structural data from the preprocessing app's PostgreSQL database
2. Generates individual LightRAG "bone" documents — one per structural entity or
   small logical unit
3. Uses LightRAG's `delete_by_doc_id` + `insert` (with explicit `ids`) to update
   individual bones when they change, WITHOUT rebuilding the entire graph
4. Keeps a sync state in Postgres to track what's been synced and when

### Key Insight: Bone-by-Bone Updates

Instead of one monolithic skeleton document, each structural element gets its own
LightRAG document with a **deterministic, stable doc ID**. When "Enersis hires a
new CFO", only the CFO's bone document is created and ingested — the rest of the
skeleton remains untouched. If someone's role changes, their bone is deleted and
re-inserted with updated content.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────┐
│     Preprocessing App (Python/Postgres)  │
│                                          │
│  ┌──────────────┐  ┌─────────────────┐  │
│  │ persons      │  │ terms           │  │
│  │ (+ aliases)  │  │ (+ variations)  │  │
│  └──────┬───────┘  └───────┬─────────┘  │
│         │                  │            │
│  ┌──────┴───────┐  ┌───────┴─────────┐  │
│  │ org_units    │  │ relationships   │  │
│  └──────────────┘  └─────────────────┘  │
│                                          │
│  ┌──────────────┐  ┌─────────────────┐  │
│  │ roles        │  │ static_entities │  │
│  └──────────────┘  └─────────────────┘  │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ skeleton_sync_state (NEW table)  │   │
│  └──────────────────────────────────┘   │
└──────────────┬──────────────────────────┘
               │
               │  Sync Module
               │  (part of the app)
               ▼
┌─────────────────────────────────────────┐
│         Bone Generator                   │
│                                          │
│  For each structural entity:             │
│  1. Generate deterministic bone_id       │
│  2. Generate LightRAG markdown content   │
│  3. Compare content hash vs last sync    │
│  4. If changed: delete old → insert new  │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│            LightRAG                      │
│                                          │
│  Each "bone" is a separate document:     │
│  ├── bone:person:florian-wolf           │
│  ├── bone:person:thomas-ceo             │
│  ├── bone:org:enersis                   │
│  ├── bone:org:enbw                      │
│  ├── bone:team:leading-team             │
│  ├── bone:role:cto-rolle                │
│  ├── bone:product:gaia                  │
│  ├── bone:domain:netzplanung            │
│  ├── bone:static:status-offen           │
│  ├── bone:temporal:2026-Q1              │
│  ├── bone:rel-cluster:enersis-hierarchy │
│  └── ...                                │
│                                          │
│  Plus diary entries (untouched by sync): │
│  ├── diary:2026-01-15                   │
│  ├── diary:2026-01-16                   │
│  └── ...                                │
└─────────────────────────────────────────┘
```

---

## 3. LightRAG Capabilities Used

Based on the current LightRAG API, the sync relies on these methods:

```python
# Insert with explicit document IDs (critical for bone-by-bone updates)
rag.insert(content, ids=["bone:person:florian-wolf"])

# Delete a specific bone by its document ID
rag.delete_by_doc_id("bone:person:florian-wolf")

# Insert pre-structured knowledge graph data (alternative to markdown)
rag.insert_custom_kg({
    "entities": [...],
    "relationships": [...],
    "chunks": [...]
})

# Delete by entity name (useful for cleanup)
rag.delete_by_entity("Old Entity Name")
```

> **[ASSUMPTION]**: The preprocessing app's LightRAG instance supports the `ids`
> parameter in `insert()` and the `delete_by_doc_id()` method. These were added
> in late 2024 / early 2025. If using the tomorrowflow/LightRAG fork, verify
> these methods exist. If not, they need to be cherry-picked from upstream HKUDS/LightRAG.

> **[ASSUMPTION]**: LightRAG is initialized with a persistent storage backend
> (e.g., PostgreSQL-backed vector store, or file-based working_dir). The sync
> relies on document IDs persisting across restarts.

---

## 4. Bone ID Convention

Every skeleton document gets a deterministic, human-readable ID:

```
bone:{category}:{slug}
```

### ID Generation Rules

```python
import re
from hashlib import md5

def generate_bone_id(category: str, name: str) -> str:
    """
    Generate a stable, deterministic bone document ID.
    
    Examples:
        generate_bone_id("person", "Florian Wolf")  → "bone:person:florian-wolf"
        generate_bone_id("org", "Enersis Europe GmbH") → "bone:org:enersis-europe-gmbh"
        generate_bone_id("static", "Status-Offen") → "bone:static:status-offen"
        generate_bone_id("temporal", "2026-Q1") → "bone:temporal:2026-q1"
        generate_bone_id("rel-cluster", "enersis-hierarchy") → "bone:rel-cluster:enersis-hierarchy"
    """
    slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
    return f"bone:{category}:{slug}"
```

### Categories

| Category | Source | Example bone_id |
|---|---|---|
| `person` | persons table | `bone:person:florian-wolf` |
| `org` | org_units WHERE type=Organization | `bone:org:enersis` |
| `team` | org_units WHERE type=Team | `bone:team:leading-team` |
| `stakeholder` | org_units WHERE type=StakeholderGroup | `bone:stakeholder:beirat` |
| `product` | org_units WHERE type=Product | `bone:product:gaia` |
| `domain` | org_units WHERE type=Domain | `bone:domain:netzplanung` |
| `capability` | org_units WHERE type=Capability | `bone:capability:data-platform` |
| `role` | roles table | `bone:role:cto-rolle` |
| `term` | terms table | `bone:term:flight-levels` |
| `initiative` | initiatives table | `bone:initiative:p2p-transformation` |
| `static` | static_entities table | `bone:static:status-offen` |
| `temporal` | generated programmatically | `bone:temporal:2026-q1` |
| `rel-cluster` | relationships (grouped) | `bone:rel-cluster:enersis-hierarchy` |

---

## 5. PostgreSQL Schema

### 5.1 Existing Tables — Assumptions

> **[ASSUMPTION]**: The preprocessing app already has tables for persons and terms.
> The exact table names, column names, and data types need to be verified against
> the actual schema. Below are the assumed structures. **Claude Code should compare
> these against the actual database schema and adapt accordingly.**

```sql
-- [ASSUMPTION] Persons table — may be called team_roster, persons, people, etc.
-- Expected columns (names may differ):
--   id, canonical_name/name, first_name, last_name, role/roles, 
--   department, company/organization, topics, status, timestamps

-- [ASSUMPTION] Person aliases/variations table
-- Expected columns:
--   id, person_id (FK), variation/alias, type, approved/active

-- [ASSUMPTION] Terms table — may be called terms, glossary, terms_roster, etc.
-- Expected columns:
--   id, canonical_term/name, category/type, context/description, 
--   status, timestamps

-- [ASSUMPTION] Term variations table
-- Expected columns:
--   id, term_id (FK), variation, approved/active
```

### 5.2 New Tables

These tables need to be added to the preprocessing app's database:

```sql
-- Organizational units: companies, teams, products, domains, capabilities
-- [ASSUMPTION]: No table like this exists yet. If something similar exists 
-- (e.g., a companies or organizations table), adapt this to extend it.
CREATE TABLE org_units (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    entity_type TEXT NOT NULL CHECK (entity_type IN (
        'Organization', 'Team', 'StakeholderGroup', 
        'Product', 'Domain', 'Capability'
    )),
    parent_id INTEGER REFERENCES org_units(id),  -- for hierarchy
    properties JSONB DEFAULT '{}',
    description TEXT,
    aliases TEXT[] DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_org_units_type ON org_units(entity_type);
CREATE INDEX idx_org_units_status ON org_units(status);
CREATE INDEX idx_org_units_updated ON org_units(updated_at);

-- Relationships between any entities (org-to-org, person-to-org, etc.)
CREATE TABLE entity_relationships (
    id SERIAL PRIMARY KEY,
    source_type TEXT NOT NULL,   -- 'person', 'org_unit', 'term', 'initiative'
    source_id INTEGER NOT NULL,  -- FK depends on source_type
    relationship_type TEXT NOT NULL,  -- 'PART_OF', 'LEADS', 'OWNS', etc.
    target_type TEXT NOT NULL,
    target_id INTEGER NOT NULL,
    context TEXT,                 -- why this relationship exists
    bidirectional BOOLEAN DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_rel_source ON entity_relationships(source_type, source_id);
CREATE INDEX idx_rel_target ON entity_relationships(target_type, target_id);
CREATE INDEX idx_rel_updated ON entity_relationships(updated_at);

-- Role assignments: who holds which responsibility
-- [ASSUMPTION]: The existing persons table may have a 'role' column.
-- This table adds richer role tracking with history and scope.
CREATE TABLE role_assignments (
    id SERIAL PRIMARY KEY,
    person_id INTEGER NOT NULL,   -- [ASSUMPTION] FK to persons table
    role_name TEXT NOT NULL,       -- e.g. 'CTO', 'Product Manager'
    role_entity_name TEXT,         -- LightRAG entity name, e.g. 'CTO-Rolle'
    scope TEXT,                    -- what the role covers
    org_unit_id INTEGER REFERENCES org_units(id),  -- role is within this org
    status TEXT NOT NULL DEFAULT 'active',
    start_date DATE,
    end_date DATE,                 -- NULL if current
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Static entities: statuses, priorities, categories
-- [ASSUMPTION]: These may currently be hardcoded or in a config file.
CREATE TABLE static_entities (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,      -- e.g. 'Status-Offen'
    entity_type TEXT NOT NULL CHECK (entity_type IN ('Status', 'Priority', 'Category')),
    properties JSONB DEFAULT '{}', -- e.g. {"transitions_to": ["InArbeit", "Blockiert"]}
    description TEXT,
    aliases TEXT[] DEFAULT '{}',
    sort_order INTEGER DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Standing initiatives, strategic objectives, known frameworks
-- [ASSUMPTION]: No dedicated table for this exists. These may currently be
-- mentioned only in diary entries without pre-existing structure.
CREATE TABLE initiatives (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    initiative_type TEXT NOT NULL CHECK (initiative_type IN (
        'Initiative', 'Objective', 'Concept', 'Method'
    )),
    properties JSONB DEFAULT '{}',
    description TEXT,
    aliases TEXT[] DEFAULT '{}',
    owner_person_id INTEGER,       -- [ASSUMPTION] FK to persons table
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN (
        'active', 'completed', 'paused', 'cancelled'
    )),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sync state tracking: one row per bone document
CREATE TABLE skeleton_sync_state (
    id SERIAL PRIMARY KEY,
    bone_id TEXT NOT NULL UNIQUE,      -- e.g. 'bone:person:florian-wolf'
    source_table TEXT NOT NULL,        -- which table this bone derives from
    source_id INTEGER NOT NULL,        -- row ID in source table
    content_hash TEXT NOT NULL,        -- MD5 of generated markdown
    last_synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sync_status TEXT NOT NULL DEFAULT 'synced' CHECK (sync_status IN (
        'synced', 'pending', 'failed', 'deleted'
    )),
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_sync_bone_id ON skeleton_sync_state(bone_id);
CREATE INDEX idx_sync_source ON skeleton_sync_state(source_table, source_id);
CREATE INDEX idx_sync_status ON skeleton_sync_state(sync_status);

-- Sync run log: one row per sync execution
CREATE TABLE skeleton_sync_log (
    id SERIAL PRIMARY KEY,
    sync_mode TEXT NOT NULL CHECK (sync_mode IN ('full', 'incremental', 'single')),
    bones_created INTEGER DEFAULT 0,
    bones_updated INTEGER DEFAULT 0,
    bones_deleted INTEGER DEFAULT 0,
    bones_unchanged INTEGER DEFAULT 0,
    duration_ms INTEGER,
    status TEXT NOT NULL CHECK (status IN ('success', 'partial', 'failed')),
    error_details TEXT,
    triggered_by TEXT,                 -- 'cli', 'webhook', 'pre-ingestion', 'cron'
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 5.3 Updated Timestamp Trigger

All source tables need an `updated_at` trigger for incremental sync:

```sql
-- [ASSUMPTION]: This trigger may already exist on some tables.
-- Apply to all tables that feed into skeleton generation.
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to each table (example):
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON org_units
    FOR EACH ROW
    EXECUTE FUNCTION update_timestamp();

-- Repeat for: entity_relationships, role_assignments, 
--             static_entities, initiatives
-- [ASSUMPTION]: Check if persons and terms tables already have this.
```

---

## 6. Bone Generation

### 6.1 Bone Types and Their Content

Each bone type maps to a source table and generates specific LightRAG markdown:

#### Person Bone

Source: persons table + aliases + role_assignments + entity_relationships

```python
def generate_person_bone(person, aliases, roles, relationships) -> str:
    """
    One bone per person. Includes their identity, roles, and 
    direct relationships.
    
    [ASSUMPTION]: 'person' is a row from the persons table.
    Adapt field names to match actual schema.
    """
    role_descriptions = []
    for r in roles:
        if r.status == 'active':
            role_descriptions.append(
                f"{r.role_name} bei {r.org_unit_name}, "
                f"verantwortlich für {r.scope}"
            )
    
    alias_list = [person.canonical_name] + [a.variation for a in aliases if a.approved]
    
    content = f"""ENTITY: {person.canonical_name}
TYPE: Person
PROPERTIES: {{role: "{', '.join(r.role_name for r in roles)}", company: "{person.company}", department: "{person.department}"}}
DESCRIPTION: {person.canonical_name} ist {'; '.join(role_descriptions)}.
ALIASES: {alias_list}
"""
    # Add direct relationships for this person
    for rel in relationships:
        content += f"""
RELATIONSHIP: {person.canonical_name} --[{rel.relationship_type}]--> {rel.target_name}
CONTEXT: {rel.context}
"""
    return content
```

#### Org Unit Bone

Source: org_units table

```python
def generate_org_bone(org_unit, child_units=None) -> str:
    """
    One bone per organizational unit (company, team, product, etc.)
    Includes parent relationship and immediate children.
    """
    content = f"""ENTITY: {org_unit.name}
TYPE: {org_unit.entity_type}
PROPERTIES: {json.dumps(org_unit.properties)}
DESCRIPTION: {org_unit.description}
ALIASES: {org_unit.aliases}
"""
    if org_unit.parent_id:
        content += f"""
RELATIONSHIP: {org_unit.name} --[PART_OF]--> {parent_name}
CONTEXT: {org_unit.name} gehört zu {parent_name}
"""
    if child_units:
        for child in child_units:
            content += f"""
RELATIONSHIP: {child.name} --[PART_OF]--> {org_unit.name}
CONTEXT: {child.name} gehört zu {org_unit.name}
"""
    return content
```

#### Relationship Cluster Bone

Relationships are grouped into logical clusters to avoid excessive fragmentation:

```python
def generate_relationship_cluster(cluster_name, relationships) -> str:
    """
    Group related relationships into one bone.
    
    Clustering strategy:
    - All relationships involving the same org unit → one cluster
      e.g., 'bone:rel-cluster:enersis-hierarchy' contains all 
      PART_OF, LEADS, DEVELOPS relationships around Enersis
    - Cross-org collaborations → one cluster
      e.g., 'bone:rel-cluster:enbw-sisters' for Enersis-Retoflow-SMIGHT
    
    When one relationship changes, only its cluster bone is updated.
    This is a tradeoff: more granular than one big skeleton,
    less granular than one bone per relationship (which would be too noisy).
    """
    content = f"# Relationship Cluster: {cluster_name}\n\n"
    for rel in relationships:
        content += f"""RELATIONSHIP: {rel.source_name} --[{rel.relationship_type}]--> {rel.target_name}
CONTEXT: {rel.context}
BIDIRECTIONAL: {"yes" if rel.bidirectional else "no"}

"""
    return content
```

#### Static Entity Bone

```python
def generate_static_bone(entity) -> str:
    """One bone per static entity (status, priority, category)."""
    content = f"""ENTITY: {entity.name}
TYPE: {entity.entity_type}
PROPERTIES: {json.dumps(entity.properties)}
DESCRIPTION: {entity.description}
ALIASES: {entity.aliases}
"""
    # For status entities, add transitions
    transitions = entity.properties.get('transitions_to', [])
    for target in transitions:
        content += f"""
RELATIONSHIP: {entity.name} --[TRANSITIONS_TO]--> Status-{target}
CONTEXT: Statusübergang von {entity.name} nach {target}
"""
    return content
```

#### Temporal Bone

```python
def generate_temporal_bone(period_type: str, identifier: str, 
                           start_date, end_date) -> str:
    """
    Generated programmatically, not from a database table.
    One bone per quarter (quarters contain weeks implicitly via dates).
    
    Only generate quarters — weeks and days are too granular for skeleton.
    Diary entries create Day entities as needed.
    """
    content = f"""ENTITY: {identifier}
TYPE: {period_type}
PROPERTIES: {{start_date: "{start_date}", end_date: "{end_date}"}}
DESCRIPTION: {period_type} {identifier} ({start_date} bis {end_date})
ALIASES: ["{identifier}"]
"""
    return content
```

### 6.2 Content Hashing

The sync engine uses content hashes to detect changes:

```python
import hashlib

def compute_content_hash(content: str) -> str:
    """
    MD5 hash of the generated bone content.
    Used to detect whether a bone has actually changed
    since last sync, avoiding unnecessary delete+insert cycles.
    """
    return hashlib.md5(content.strip().encode('utf-8')).hexdigest()
```

---

## 7. Sync Engine

### 7.1 Core Sync Logic

```python
class SkeletonSyncEngine:
    """
    Orchestrates bone-by-bone sync between Postgres and LightRAG.
    
    [ASSUMPTION]: The preprocessing app has a database session/connection
    management pattern. Adapt the DB access to match the actual ORM 
    (SQLAlchemy, raw psycopg2, asyncpg, etc.)
    
    [ASSUMPTION]: LightRAG is accessible either as a Python object 
    (in-process) or via HTTP API. This spec shows the Python API.
    Adapt if using the HTTP API (POST /documents, DELETE /documents/{id}).
    """
    
    def __init__(self, db, rag: LightRAG):
        self.db = db          # Postgres connection/session
        self.rag = rag        # LightRAG instance
    
    async def sync_incremental(self, triggered_by: str = "manual"):
        """
        Sync only bones whose source data has changed since last sync.
        
        Algorithm:
        1. For each source table, find rows where updated_at > last_sync
        2. Generate bone content for changed rows
        3. Compare content hash with stored hash
        4. If different: delete_by_doc_id → insert with same ID
        5. If same: skip (data changed but bone content didn't)
        6. Check for deleted source rows → delete orphaned bones
        """
        stats = SyncStats()
        last_sync = self._get_last_sync_timestamp()
        
        # Process each bone category
        for category, generator in self._get_generators():
            changed_records = generator.get_changed_since(last_sync)
            
            for record in changed_records:
                bone_id = generator.make_bone_id(record)
                content = generator.generate_content(record)
                content_hash = compute_content_hash(content)
                
                existing = self._get_sync_state(bone_id)
                
                if existing is None:
                    # New bone — just insert
                    await self.rag.insert(content, ids=[bone_id])
                    self._save_sync_state(bone_id, generator.source_table,
                                          record.id, content_hash)
                    stats.created += 1
                    
                elif existing.content_hash != content_hash:
                    # Changed bone — delete old, insert new
                    await self.rag.delete_by_doc_id(bone_id)
                    await self.rag.insert(content, ids=[bone_id])
                    self._update_sync_state(bone_id, content_hash)
                    stats.updated += 1
                    
                else:
                    stats.unchanged += 1
            
            # Check for deletions
            deleted_bones = generator.find_deleted_bones(self.db)
            for bone_id in deleted_bones:
                await self.rag.delete_by_doc_id(bone_id)
                self._mark_deleted(bone_id)
                stats.deleted += 1
        
        self._log_sync_run("incremental", stats, triggered_by)
        return stats
    
    async def sync_single_bone(self, bone_id: str):
        """
        Sync a single bone. Used when a specific record changes
        (e.g., triggered by a database event or webhook).
        
        Example: After updating a person's role in the app UI,
        call sync_single_bone("bone:person:florian-wolf")
        """
        category, slug = self._parse_bone_id(bone_id)
        generator = self._get_generator(category)
        record = generator.get_by_slug(slug)
        
        if record is None:
            # Source record was deleted
            await self.rag.delete_by_doc_id(bone_id)
            self._mark_deleted(bone_id)
            return "deleted"
        
        content = generator.generate_content(record)
        content_hash = compute_content_hash(content)
        existing = self._get_sync_state(bone_id)
        
        if existing and existing.content_hash == content_hash:
            return "unchanged"
        
        if existing:
            await self.rag.delete_by_doc_id(bone_id)
        
        await self.rag.insert(content, ids=[bone_id])
        self._save_or_update_sync_state(bone_id, generator.source_table,
                                         record.id, content_hash)
        return "updated" if existing else "created"
    
    async def sync_full(self, triggered_by: str = "manual"):
        """
        Full sync: re-generate and re-sync ALL bones.
        Does NOT touch diary entries — only bone:* documents.
        
        Process:
        1. Generate all bones from current database state
        2. For each: compare hash → skip if unchanged, update if changed
        3. Delete any bones in sync_state that no longer have source data
        4. This is safe because diary documents use 'diary:*' IDs,
           not 'bone:*' IDs, so they are never affected.
        """
        stats = SyncStats()
        
        all_expected_bone_ids = set()
        
        for category, generator in self._get_generators():
            all_records = generator.get_all_active()
            
            for record in all_records:
                bone_id = generator.make_bone_id(record)
                all_expected_bone_ids.add(bone_id)
                content = generator.generate_content(record)
                content_hash = compute_content_hash(content)
                
                existing = self._get_sync_state(bone_id)
                
                if existing and existing.content_hash == content_hash:
                    stats.unchanged += 1
                    continue
                
                if existing:
                    await self.rag.delete_by_doc_id(bone_id)
                    stats.updated += 1
                else:
                    stats.created += 1
                
                await self.rag.insert(content, ids=[bone_id])
                self._save_or_update_sync_state(bone_id, generator.source_table,
                                                 record.id, content_hash)
        
        # Clean up orphaned bones
        all_synced = self._get_all_synced_bone_ids()
        orphans = all_synced - all_expected_bone_ids
        for bone_id in orphans:
            await self.rag.delete_by_doc_id(bone_id)
            self._mark_deleted(bone_id)
            stats.deleted += 1
        
        self._log_sync_run("full", stats, triggered_by)
        return stats
```

### 7.2 Change Detection

```python
class BoneGenerator:
    """
    Base class for bone generators. Each subclass handles one 
    source table / bone category.
    """
    source_table: str
    category: str
    
    def get_changed_since(self, since: datetime) -> List[Record]:
        """Query source table for records updated after 'since'."""
        return self.db.query(
            f"SELECT * FROM {self.source_table} "
            f"WHERE updated_at > %s AND status = 'active'",
            [since]
        )
    
    def find_deleted_bones(self) -> List[str]:
        """
        Find bones in sync_state whose source records no longer exist
        or have been set to inactive.
        """
        return self.db.query("""
            SELECT s.bone_id 
            FROM skeleton_sync_state s
            LEFT JOIN {source_table} t ON s.source_id = t.id
            WHERE s.source_table = %s
              AND s.sync_status = 'synced'
              AND (t.id IS NULL OR t.status = 'inactive')
        """, [self.source_table])
```

### 7.3 The CFO Example — Walkthrough

Your example: "Enersis hires a new CFO." Here's exactly what happens:

```
1. User adds new person "Maria Schmidt" to persons table via the app
   → persons row created with canonical_name="Maria Schmidt", 
     company="Enersis", status="active"

2. User creates role_assignment: 
   → person_id=Maria's ID, role_name="CFO", 
     org_unit_id=Enersis's ID, status="active"

3. Sync is triggered (webhook, pre-ingestion hook, or manual)

4. PersonBoneGenerator detects Maria as new (no sync_state entry)
   → Generates bone content:
     """
     ENTITY: Maria Schmidt
     TYPE: Person
     PROPERTIES: {role: "CFO", company: "Enersis"}
     DESCRIPTION: Maria Schmidt ist CFO bei Enersis, verantwortlich 
     für Finance und Controlling.
     ALIASES: ["Maria Schmidt", "Maria"]
     
     RELATIONSHIP: Maria Schmidt --[BELONGS_TO]--> Enersis
     CONTEXT: Maria Schmidt arbeitet bei Enersis als CFO
     
     RELATIONSHIP: Maria Schmidt --[HOLDS_ROLE]--> CFO-Rolle
     CONTEXT: Maria Schmidt hat die Rolle CFO bei Enersis
     """
   → Calls: rag.insert(content, ids=["bone:person:maria-schmidt"])
   → Saves sync_state: bone_id="bone:person:maria-schmidt", 
     content_hash="abc123..."

5. No other bones are touched. The bone for Enersis, for Thomas, 
   for the Leading-Team — all remain as-is.

6. The NEXT time someone mentions "Maria" in a diary entry, 
   LightRAG's extraction will find the existing "Maria Schmidt" 
   entity in the graph and connect the diary content to it.
```

And if Maria's role later changes from CFO to COO:

```
1. User updates role_assignment: role_name="COO"
   → updated_at timestamp changes

2. Incremental sync detects the change via updated_at

3. PersonBoneGenerator regenerates Maria's bone with new role
   → New content has different hash than stored hash

4. Sync engine:
   → rag.delete_by_doc_id("bone:person:maria-schmidt")
   → rag.insert(new_content, ids=["bone:person:maria-schmidt"])
   → Updates sync_state with new content_hash

5. All diary entries that previously mentioned Maria still exist 
   and still reference the "Maria Schmidt" entity — because the 
   entity NAME hasn't changed, only its description and properties.
```

---

## 8. Relationship Clustering Strategy

Individual relationships are too granular as bones (too many, too noisy). But one
big relationship document is too coarse (any change requires full rebuild). The
middle ground: **cluster relationships by their primary entity**.

```python
CLUSTER_STRATEGY = {
    # All relationships where an org unit is source or target
    # → one cluster per org unit
    "org_unit": lambda rel: (
        f"bone:rel-cluster:{slugify(rel.source_name)}-rels"
        if rel.source_type == "org_unit"
        else f"bone:rel-cluster:{slugify(rel.target_name)}-rels"
    ),
    
    # Person relationships are part of the person bone (not separate)
    "person": None,  # included in person bone
    
    # Cross-entity relationships (e.g., initiative → objective)
    # → cluster by initiative
    "initiative": lambda rel: f"bone:rel-cluster:{slugify(rel.source_name)}-rels",
}
```

This means:
- Person relationships are embedded in the person bone (deleted/updated together)
- Org unit relationships get one cluster bone per org unit
- When a relationship changes, only its cluster bone is rebuilt

---

## 9. Integration with Diary Ingestion Pipeline

> **[ASSUMPTION]**: The diary ingestion pipeline currently works roughly as:
> 1. Audio → STT transcription
> 2. Name normalization (using dictionary)
> 3. LLM processing (entity extraction, TODOs, insights, etc.)
> 4. Insert processed markdown into LightRAG
>
> Verify the actual pipeline stages and where skeleton sync should hook in.

### Pre-Ingestion Hook

```python
async def ingest_diary_entry(transcript: str, date: str):
    """
    [ASSUMPTION]: This function or something similar exists.
    Add the ensure_skeleton_current() call at the start.
    """
    # Step 0: Ensure skeleton is current
    sync_engine = SkeletonSyncEngine(db, rag)
    sync_result = await sync_engine.sync_incremental(
        triggered_by="pre-ingestion"
    )
    if sync_result.has_changes():
        logger.info(f"Skeleton updated: {sync_result}")
    
    # Step 1: Name normalization (existing)
    # Step 2: LLM processing (existing)
    # Step 3: Insert into LightRAG with diary ID
    diary_id = f"diary:{date}"
    await rag.insert(processed_content, ids=[diary_id])
```

### Diary Document ID Convention

To ensure diary entries are never affected by skeleton sync:

```python
# Skeleton bones always use: bone:*
# Diary entries always use:  diary:*
# This separation is critical — sync_full only touches bone:* documents.

diary_id = f"diary:{date}"                    # diary:2026-04-01
diary_id = f"diary:{date}:{sequence}"          # diary:2026-04-01:2 (if multiple per day)
```

---

## 10. CLI and API

### CLI Commands

```bash
# Show sync status
python -m skeleton_sync status
# Output: Last sync at 2026-04-01T10:30:00, 47 bones synced, 0 pending

# Dry run — show what would change
python -m skeleton_sync diff
# Output: 
#   NEW:     bone:person:maria-schmidt (persons.id=42)
#   CHANGED: bone:role:cto-rolle (content hash mismatch)
#   DELETED: bone:person:old-contractor (source row inactive)
#   UNCHANGED: 44 bones

# Incremental sync
python -m skeleton_sync sync
python -m skeleton_sync sync --mode incremental

# Full sync (safe — only touches bone:* documents)
python -m skeleton_sync sync --mode full

# Sync a single bone
python -m skeleton_sync sync --bone bone:person:maria-schmidt

# Generate bone content for inspection (no ingestion)
python -m skeleton_sync render --bone bone:person:florian-wolf
python -m skeleton_sync render --all --output ./skeleton_preview/

# Validate: check for orphaned relationships, missing roles, etc.
python -m skeleton_sync validate

# Temporal spine: regenerate for current/next quarter
python -m skeleton_sync temporal --regenerate
```

### Integration API

> **[ASSUMPTION]**: The preprocessing app has some kind of API layer 
> (FastAPI, Flask, etc.). If so, add these endpoints. If not, the CLI 
> is sufficient.

```python
# POST /api/skeleton/sync
# Body: {"mode": "incremental"} or {"mode": "full"}
# Returns: {"created": 1, "updated": 0, "deleted": 0, "unchanged": 46}

# POST /api/skeleton/sync/{bone_id}
# Syncs a single bone
# Returns: {"status": "updated", "bone_id": "bone:person:maria-schmidt"}

# GET /api/skeleton/status
# Returns: {"last_sync": "...", "total_bones": 47, "pending": 0}

# GET /api/skeleton/diff
# Returns: {"new": [...], "changed": [...], "deleted": [...], "unchanged": 44}
```

---

## 11. Trigger Mechanisms

### Option A: Database Trigger + NOTIFY (Recommended for Postgres)

```sql
-- Postgres LISTEN/NOTIFY for real-time change detection
CREATE OR REPLACE FUNCTION notify_skeleton_change()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('skeleton_change', json_build_object(
        'table', TG_TABLE_NAME,
        'operation', TG_OP,
        'id', COALESCE(NEW.id, OLD.id)
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all source tables
CREATE TRIGGER skeleton_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON org_units
    FOR EACH ROW EXECUTE FUNCTION notify_skeleton_change();

-- Repeat for: entity_relationships, role_assignments, 
--             static_entities, initiatives
-- [ASSUMPTION]: For persons and terms tables too, if they should 
-- trigger skeleton sync on change.
```

The sync service listens for these notifications:

```python
import asyncpg

async def listen_for_changes(db_url: str, sync_engine: SkeletonSyncEngine):
    """
    Listen for Postgres NOTIFY events and trigger bone-level sync.
    
    [ASSUMPTION]: The app uses asyncpg or similar async Postgres driver.
    Adapt if using psycopg2 or SQLAlchemy.
    """
    conn = await asyncpg.connect(db_url)
    await conn.add_listener('skeleton_change', 
        lambda conn, pid, channel, payload: 
            handle_change(sync_engine, json.loads(payload))
    )

async def handle_change(sync_engine, payload):
    table = payload['table']
    record_id = payload['id']
    
    # Determine which bone(s) are affected
    affected_bones = sync_engine.get_bones_for_source(table, record_id)
    
    for bone_id in affected_bones:
        await sync_engine.sync_single_bone(bone_id)
```

### Option B: Pre-Ingestion Check

```python
# Simpler: just check timestamps before each diary ingestion
# Less real-time but zero additional infrastructure
await sync_engine.sync_incremental(triggered_by="pre-ingestion")
```

### Option C: Periodic Cron

```bash
# Safety net: nightly full sync
0 2 * * * cd /app && python -m skeleton_sync sync --mode full
```

These are not mutually exclusive. Recommended: **Option A + Option C** for
real-time updates with a nightly safety net.

---

## 12. Edge Cases and Considerations

### Entity Name Changes

If a person's canonical name changes (marriage, correction), this is the
trickiest case because diary entries already reference the old name:

```python
# The bone_id changes too (it's derived from the name)
# Old: bone:person:maria-schmidt
# New: bone:person:maria-mueller

# Strategy:
# 1. Delete old bone: rag.delete_by_doc_id("bone:person:maria-schmidt")
# 2. Insert new bone: rag.insert(content, ids=["bone:person:maria-mueller"])
# 3. Old diary entries still reference "Maria Schmidt" as an entity name
#    → These become orphaned references in the graph
# 4. Consider adding the old name as an alias in the new bone
#    → LightRAG may connect them during future queries
# 5. For full consistency: requires diary re-ingestion (expensive)
```

### Relationship Clusters and Cascading Updates

When an org unit is renamed or restructured, its relationship cluster bone
must also be updated:

```python
# When updating bone:org:enersis, also check:
# - bone:rel-cluster:enersis-rels (relationships involving Enersis)
# - All person bones for people belonging to Enersis
# The sync engine should track these dependencies.
```

### First-Time Initialization

On first run (empty sync_state table), the sync engine should:

```
1. Run sync --mode full to create all bones
2. This is safe even if LightRAG already has manually-ingested skeleton
   data — the old data will remain, and new bone documents are added
3. To start clean: clear LightRAG first, then sync --mode full, 
   then re-ingest diary archive
```

### Temporal Spine Management

```python
# Temporal bones are special: they're generated, not from a table
# Re-generate quarterly:
# - At the start of each quarter, generate next quarter's bone
# - Keep past quarters' bones (they anchor diary entries)
# - Never delete temporal bones that have diary entries referencing them
```

---

## 13. For Claude Code: Review Checklist

Before implementing, verify these against the actual codebase:

```
□ Database schema: What are the actual table names and column names 
  for persons, terms, and their variations?
  
□ ORM/DB access: Does the app use SQLAlchemy, raw SQL, asyncpg, 
  psycopg2, or something else?

□ LightRAG integration: Is LightRAG used as an in-process Python 
  object or via HTTP API? Which fork (HKUDS/LightRAG or 
  tomorrowflow/LightRAG)?

□ LightRAG version: Does the current version support insert(ids=...) 
  and delete_by_doc_id()? If not, update to latest upstream.

□ App structure: Where should the skeleton_sync module live? 
  Is there an existing module pattern to follow?

□ Configuration: How does the app manage config (env vars, 
  config files, dataclass)? Follow the same pattern.

□ Existing skeleton data: Is there already manually-ingested 
  skeleton data in LightRAG that needs migration?

□ Diary ID convention: How are diary documents currently identified 
  in LightRAG? Do they use IDs, or auto-generated hashes?

□ API layer: Does the app expose an API (FastAPI, Flask)? 
  If so, add sync endpoints.

□ Async patterns: Is the app async (asyncio) or sync? 
  LightRAG's delete/insert methods may be async.

□ Testing: What's the testing pattern? Add tests for bone 
  generation and sync logic.
```
