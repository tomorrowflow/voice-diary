-- Diary Processor Review Webapp Schema

CREATE TABLE IF NOT EXISTS persons (
    id SERIAL PRIMARY KEY,
    canonical_name VARCHAR(200) NOT NULL UNIQUE,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    role VARCHAR(300),
    department VARCHAR(200),
    company VARCHAR(200),
    context TEXT,
    topics TEXT,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS person_variations (
    id SERIAL PRIMARY KEY,
    person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    variation VARCHAR(200) NOT NULL,
    variation_type VARCHAR(50) DEFAULT 'asr_correction',
    confidence VARCHAR(20) DEFAULT 'high',
    approved BOOLEAN DEFAULT TRUE,
    auto_created BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(person_id, variation)
);

CREATE TABLE IF NOT EXISTS terms (
    id SERIAL PRIMARY KEY,
    canonical_term VARCHAR(300) NOT NULL UNIQUE,
    category VARCHAR(50) NOT NULL,
    context TEXT,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS term_variations (
    id SERIAL PRIMARY KEY,
    term_id INTEGER NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
    variation VARCHAR(300) NOT NULL,
    approved BOOLEAN DEFAULT TRUE,
    auto_created BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(term_id, variation)
);

CREATE TABLE IF NOT EXISTS transcripts (
    id SERIAL PRIMARY KEY,
    filename VARCHAR(200) NOT NULL,
    date DATE NOT NULL,
    author VARCHAR(200),
    raw_text TEXT NOT NULL,
    corrected_text TEXT,
    entities_json JSONB,
    status VARCHAR(20) DEFAULT 'pending',
    submitted_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- migration: add entities_json if missing
ALTER TABLE transcripts ADD COLUMN IF NOT EXISTS entities_json JSONB;
-- migration: add processing_error if missing
ALTER TABLE transcripts ADD COLUMN IF NOT EXISTS processing_error TEXT;
-- migration: add context to persons if missing
ALTER TABLE persons ADD COLUMN IF NOT EXISTS context TEXT;

CREATE TABLE IF NOT EXISTS review_log (
    id SERIAL PRIMARY KEY,
    transcript_id INTEGER NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
    original_text VARCHAR(500) NOT NULL,
    corrected_text VARCHAR(500) NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    match_type VARCHAR(50) NOT NULL,
    action VARCHAR(50) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS harvest_entries (
    id SERIAL PRIMARY KEY,
    harvest_id BIGINT UNIQUE NOT NULL,
    spent_date DATE NOT NULL,
    hours NUMERIC(6,2) NOT NULL,
    notes TEXT,
    project_id BIGINT,
    project_name VARCHAR(300),
    task_id BIGINT,
    task_name VARCHAR(300),
    client_name VARCHAR(300),
    raw_json JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_harvest_entries_date ON harvest_entries (spent_date);

CREATE TABLE IF NOT EXISTS text_corrections (
    id SERIAL PRIMARY KEY,
    original_text VARCHAR(500) NOT NULL,
    corrected_text VARCHAR(500) NOT NULL,
    correction_type VARCHAR(50) NOT NULL,
    context VARCHAR(500),
    case_sensitive BOOLEAN DEFAULT FALSE,
    use_count INTEGER DEFAULT 1,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(original_text, corrected_text)
);

CREATE TABLE IF NOT EXISTS app_settings (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ingest_uploads (
    id SERIAL PRIMARY KEY,
    filename VARCHAR(500) NOT NULL,
    file_size BIGINT,
    status VARCHAR(20) NOT NULL DEFAULT 'queued',
    error_message TEXT,
    transcript_id INTEGER REFERENCES transcripts(id) ON DELETE SET NULL,
    review_url VARCHAR(200),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ingest_uploads_status ON ingest_uploads (status);
CREATE INDEX IF NOT EXISTS idx_ingest_uploads_created ON ingest_uploads (created_at DESC);

CREATE TABLE IF NOT EXISTS processed_documents (
    id SERIAL PRIMARY KEY,
    transcript_id INTEGER NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
    version INTEGER NOT NULL DEFAULT 1,
    document_markdown TEXT NOT NULL,
    analysis_json JSONB,
    context_summary TEXT,
    metadata JSONB,
    lightrag_ingested BOOLEAN DEFAULT FALSE,
    lightrag_ingested_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(transcript_id, version)
);

CREATE INDEX IF NOT EXISTS idx_processed_documents_transcript ON processed_documents (transcript_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_transcripts_filename_date ON transcripts (filename, date);
CREATE INDEX IF NOT EXISTS idx_person_variations_lower ON person_variations (LOWER(variation));
CREATE INDEX IF NOT EXISTS idx_term_variations_lower ON term_variations (LOWER(variation));
CREATE INDEX IF NOT EXISTS idx_transcripts_status ON transcripts (status);
CREATE INDEX IF NOT EXISTS idx_persons_status ON persons (status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_terms_status ON terms (status) WHERE status = 'active';

-- ═══════════════════════════════════════════════════════════════════
-- Skeleton Sync: structural entities + sync state
-- ═══════════════════════════════════════════════════════════════════

-- Organizational units: companies, teams, products, domains, capabilities
CREATE TABLE IF NOT EXISTS org_units (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    entity_type TEXT NOT NULL CHECK (entity_type IN (
        'Organization', 'Team', 'StakeholderGroup',
        'Product', 'Domain', 'Capability'
    )),
    parent_id INTEGER REFERENCES org_units(id),
    properties JSONB DEFAULT '{}',
    description TEXT,
    aliases TEXT[] DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_org_units_type ON org_units(entity_type);
CREATE INDEX IF NOT EXISTS idx_org_units_status ON org_units(status);
CREATE INDEX IF NOT EXISTS idx_org_units_updated ON org_units(updated_at);

-- Relationships between any entities (org-to-org, person-to-org, etc.)
CREATE TABLE IF NOT EXISTS entity_relationships (
    id SERIAL PRIMARY KEY,
    source_type TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    relationship_type TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id INTEGER NOT NULL,
    context TEXT,
    bidirectional BOOLEAN DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rel_source ON entity_relationships(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_rel_target ON entity_relationships(target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_rel_updated ON entity_relationships(updated_at);

-- Role assignments: who holds which responsibility
CREATE TABLE IF NOT EXISTS role_assignments (
    id SERIAL PRIMARY KEY,
    person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    role_name TEXT NOT NULL,
    role_entity_name TEXT,
    scope TEXT,
    org_unit_id INTEGER REFERENCES org_units(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'active',
    start_date DATE,
    end_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_role_assignments_person ON role_assignments(person_id);
CREATE INDEX IF NOT EXISTS idx_role_assignments_org ON role_assignments(org_unit_id);

-- Static entities: statuses, priorities, categories
CREATE TABLE IF NOT EXISTS static_entities (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('Status', 'Priority', 'Category')),
    properties JSONB DEFAULT '{}',
    description TEXT,
    aliases TEXT[] DEFAULT '{}',
    sort_order INTEGER DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Initiatives, strategic objectives, known frameworks
CREATE TABLE IF NOT EXISTS initiatives (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    initiative_type TEXT NOT NULL CHECK (initiative_type IN (
        'Initiative', 'Objective', 'Concept', 'Method'
    )),
    properties JSONB DEFAULT '{}',
    description TEXT,
    aliases TEXT[] DEFAULT '{}',
    owner_person_id INTEGER REFERENCES persons(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN (
        'active', 'completed', 'paused', 'cancelled'
    )),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Skeleton sync state: one row per bone document
CREATE TABLE IF NOT EXISTS skeleton_sync_state (
    id SERIAL PRIMARY KEY,
    bone_id TEXT NOT NULL UNIQUE,
    source_table TEXT NOT NULL,
    source_id INTEGER NOT NULL,
    content_hash TEXT NOT NULL,
    content_text TEXT,
    last_synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sync_status TEXT NOT NULL DEFAULT 'synced' CHECK (sync_status IN (
        'synced', 'pending', 'failed', 'deleted'
    )),
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sync_bone_id ON skeleton_sync_state(bone_id);
CREATE INDEX IF NOT EXISTS idx_sync_source ON skeleton_sync_state(source_table, source_id);
CREATE INDEX IF NOT EXISTS idx_sync_status ON skeleton_sync_state(sync_status);

-- Skeleton sync run log
CREATE TABLE IF NOT EXISTS skeleton_sync_log (
    id SERIAL PRIMARY KEY,
    sync_mode TEXT NOT NULL CHECK (sync_mode IN ('full', 'incremental', 'single')),
    bones_created INTEGER DEFAULT 0,
    bones_updated INTEGER DEFAULT 0,
    bones_deleted INTEGER DEFAULT 0,
    bones_unchanged INTEGER DEFAULT 0,
    bones_failed INTEGER DEFAULT 0,
    duration_ms INTEGER,
    status TEXT NOT NULL CHECK (status IN ('success', 'partial', 'failed')),
    error_details TEXT,
    triggered_by TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- updated_at trigger function
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at triggers to all source tables
DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'persons', 'terms', 'org_units', 'entity_relationships',
        'role_assignments', 'static_entities', 'initiatives'
    ] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS set_updated_at ON %I', tbl);
        EXECUTE format(
            'CREATE TRIGGER set_updated_at BEFORE UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION update_timestamp()', tbl
        );
    END LOOP;
END;
$$;
