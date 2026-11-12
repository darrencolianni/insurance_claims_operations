-- ==============================================================================
-- Insurance Claims Operations Analytics - Schema & Ingestion
-- File: sql/00_schema_and_ingestion.sql
-- Description: Creates the relational star-schema database objects, constraints,
--              indexes, and ingestion procedures for operational claims logs.
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- 1. CLEANUP (Idempotent execution)
DROP VIEW IF EXISTS v_damage_scorecard CASCADE;
DROP VIEW IF EXISTS v_transition_bottlenecks CASCADE;
DROP VIEW IF EXISTS v_process_transitions CASCADE;
DROP VIEW IF EXISTS v_claim_master CASCADE;
DROP VIEW IF EXISTS v_monthly_intake_trend CASCADE;

DROP TABLE IF EXISTS process_events CASCADE;
DROP TABLE IF EXISTS claim_summary CASCADE;
DROP TABLE IF EXISTS dim_process_state CASCADE;
DROP TABLE IF EXISTS dim_damage_type CASCADE;

-- ==============================================================================
-- 2. DIMENSION TABLES
-- ==============================================================================

-- Dimension: Damage Types (6 distinct categories in German motor insurance portfolio)
CREATE TABLE dim_damage_type (
    damage_type_id      INTEGER PRIMARY KEY,
    damage_type_name    VARCHAR(50) NOT NULL UNIQUE,
    complexity_tier     VARCHAR(20) NOT NULL
);

COMMENT ON TABLE dim_damage_type IS 'Lookup dimension for claim damage categories.';
COMMENT ON COLUMN dim_damage_type.complexity_tier IS 'Operational complexity rating (Low / Medium / High).';

INSERT INTO dim_damage_type (damage_type_id, damage_type_name, complexity_tier) VALUES
    (0, 'Glass damage',   'Low'),
    (1, 'Rodent bites',   'Low'),
    (2, 'Parking damage', 'Medium'),
    (3, 'Scorch damage',  'Medium'),
    (4, 'Animal damage',  'High'),
    (5, 'Hit & run',      'High');

-- Dimension: Process States (12 distinct operational stages)
CREATE TABLE dim_process_state (
    state_id        INTEGER PRIMARY KEY,
    state_name      VARCHAR(50) NOT NULL UNIQUE,
    phase_category  VARCHAR(30) NOT NULL,
    is_terminal     BOOLEAN NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE dim_process_state IS 'Lookup dimension for operational workflow states.';
COMMENT ON COLUMN dim_process_state.phase_category IS 'Broader workflow phase (Intake, Processing, Documentation, Investigation, Resolution).';

INSERT INTO dim_process_state (state_id, state_name, phase_category, is_terminal) VALUES
    (0,  'Rejection',               'Resolution',     TRUE),
    (1,  'Processing',              'Processing',     FALSE),
    (2,  'Document request',        'Documentation',  FALSE),
    (3,  'Cover note',              'Coverage',       FALSE),
    (4,  'Internal',                'Processing',     FALSE),
    (5,  'Audit passed',            'Resolution',     TRUE),
    (6,  'Further inquiry',         'Investigation',  FALSE),
    (7,  'Notification of claim',   'Intake',         FALSE),
    (8,  'Damage documents',        'Documentation',  FALSE),
    (9,  'Correspondence',          'Documentation',  FALSE),
    (10, 'Other',                   'Auxiliary',      FALSE),
    (11, 'Notification of payment', 'Resolution',     FALSE);

-- ==============================================================================
-- 3. FACT & SUMMARY TABLES
-- ==============================================================================

-- Claim Summary: One record per claim instance (5,131 claims)
CREATE TABLE claim_summary (
    instance_id     INTEGER PRIMARY KEY,
    damage_type     VARCHAR(50) NOT NULL,
    first_event     TIMESTAMPTZ NOT NULL,
    last_event      TIMESTAMPTZ NOT NULL,
    first_state     VARCHAR(50) NOT NULL,
    last_state      VARCHAR(50) NOT NULL,
    event_count     INTEGER NOT NULL CHECK (event_count > 0),
    total_docs      INTEGER NOT NULL CHECK (total_docs >= 0),
    total_pages     NUMERIC(8,2) DEFAULT 0 CHECK (total_pages >= 0 OR total_pages IS NULL),
    duration_days   NUMERIC(10,6) NOT NULL CHECK (duration_days >= 0),
    page_bracket    VARCHAR(30) NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE claim_summary IS 'Claim-level aggregate table tracking lifecycle duration, touchpoints, and document counts.';
COMMENT ON COLUMN claim_summary.duration_days IS 'Elapsed duration between first and last recorded events in days.';

-- Process Events: Event log (32,058 events across 5,131 claims)
CREATE TABLE process_events (
    event_id                    BIGSERIAL PRIMARY KEY,
    event_timestamp             TIMESTAMPTZ NOT NULL,
    instance_id                 INTEGER NOT NULL,
    state_id                    INTEGER NOT NULL REFERENCES dim_process_state(state_id),
    state_name                  VARCHAR(50) NOT NULL,
    type_id                     INTEGER NOT NULL REFERENCES dim_damage_type(damage_type_id),
    type_name                   VARCHAR(50) NOT NULL,
    file_name                   VARCHAR(100),
    n_pages                     NUMERIC(6,2) CHECK (n_pages >= 0 OR n_pages IS NULL),
    time_since_last_event_sec   BIGINT NOT NULL DEFAULT 0 CHECK (time_since_last_event_sec >= 0),
    log_time_since_last_event   NUMERIC(8,4) NOT NULL DEFAULT 0,
    created_at                  TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE process_events IS 'Granular transactional event logs detailing every interaction and document upload.';

-- ==============================================================================
-- 4. PERFORMANCE INDEXES
-- ==============================================================================

CREATE INDEX idx_process_events_instance_time 
    ON process_events (instance_id, event_timestamp ASC);

CREATE INDEX idx_process_events_state 
    ON process_events (state_id, state_name);

CREATE INDEX idx_process_events_type 
    ON process_events (type_id, type_name);

CREATE INDEX idx_process_events_timestamp 
    ON process_events (event_timestamp);

CREATE INDEX idx_claim_summary_damage_type 
    ON claim_summary (damage_type);

CREATE INDEX idx_claim_summary_last_state 
    ON claim_summary (last_state);

CREATE INDEX idx_claim_summary_duration 
    ON claim_summary (duration_days);

-- ==============================================================================
-- 5. DATA INGESTION
-- ==============================================================================

-- Staging table for raw CSV loading (handles column mapping & type coercion)
CREATE TEMP TABLE stage_process_log (
    timestamp                  TIMESTAMPTZ,
    instance_id                INTEGER,
    state                      INTEGER,
    file_name                  VARCHAR(100),
    n_pages                    NUMERIC(6,2),
    time_since_last_event      BIGINT,
    log_time_since_last_event  NUMERIC(8,4),
    type                       INTEGER,
    state_name                 VARCHAR(50),
    type_name                  VARCHAR(50)
);

CREATE TEMP TABLE stage_claim_summary (
    instance_id    INTEGER,
    damage_type    VARCHAR(50),
    first_event    TIMESTAMPTZ,
    last_event     TIMESTAMPTZ,
    first_state    VARCHAR(50),
    last_state     VARCHAR(50),
    event_count    INTEGER,
    total_docs     INTEGER,
    total_pages    NUMERIC(8,2),
    duration_days  NUMERIC(10,6),
    page_bracket   VARCHAR(30)
);

-- Note: When running inside Docker / devcontainer:
COPY stage_claim_summary FROM '/tmp/claim_summary.csv' WITH (FORMAT csv, HEADER true);
COPY stage_process_log   FROM '/tmp/cleaned_process_log.csv' WITH (FORMAT csv, HEADER true);

-- Ingest into target tables
INSERT INTO claim_summary (
    instance_id, damage_type, first_event, last_event, 
    first_state, last_state, event_count, total_docs, 
    total_pages, duration_days, page_bracket
)
SELECT 
    instance_id, damage_type, first_event, last_event,
    first_state, last_state, event_count, total_docs,
    COALESCE(total_pages, 0), duration_days, page_bracket
FROM stage_claim_summary;

INSERT INTO process_events (
    event_timestamp, instance_id, state_id, state_name,
    type_id, type_name, file_name, n_pages,
    time_since_last_event_sec, log_time_since_last_event
)
SELECT 
    timestamp, instance_id, state, state_name,
    type, type_name, file_name, n_pages,
    time_since_last_event, log_time_since_last_event
FROM stage_process_log
ORDER BY instance_id, timestamp;

-- Cleanup temporary staging tables
DROP TABLE stage_process_log;
DROP TABLE stage_claim_summary;

-- ==============================================================================
-- 6. VERIFICATION & ROW COUNT VALIDATION
-- ==============================================================================

DO $$
DECLARE
    claim_count INT;
    event_count INT;
BEGIN
    SELECT COUNT(*) INTO claim_count FROM claim_summary;
    SELECT COUNT(*) INTO event_count FROM process_events;
    
    RAISE NOTICE '==================================================';
    RAISE NOTICE 'Ingestion Complete:';
    RAISE NOTICE '  - claim_summary rows: % (expected: 5131)', claim_count;
    RAISE NOTICE '  - process_events rows: % (expected: 32058)', event_count;
    RAISE NOTICE '==================================================';
END $$;
