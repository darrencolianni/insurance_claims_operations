
-- ==============================================================================
-- Insurance Claims Operations Analytics - Window Functions Deep Dive
-- File: sql/01_window_functions_deep_dive.sql
-- Description: Window functions for event sequencing, claim ranking,
--              state transitions, lifecycle tracking, running aggregates,
--              moving averages, and statistical distributions.
-- Target DB: PostgreSQL 14+
-- ==============================================================================


-- ------------------------------------------------------------------------------
-- 1. ROW_NUMBER(): Chronological Sequencing & Top-N Per Category
-- ------------------------------------------------------------------------------

-- Query 1A: Chronological and Reverse Event Sequence Numbers per Claim
WITH sequenced_events AS (
    SELECT
        instance_id,
        event_timestamp,
        state_name,
        type_name,
        ROW_NUMBER() OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp ASC
        ) AS event_seq_asc,
        ROW_NUMBER() OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp DESC
        ) AS event_seq_desc
    FROM process_events
    WHERE instance_id IN (0, 1, 2, 9)
)
SELECT
    instance_id,
    event_timestamp,
    state_name,
    type_name AS damage_type,
    event_seq_asc,
    event_seq_desc,
    CASE
        WHEN event_seq_desc = 1 THEN 'Final State'
        WHEN event_seq_desc = 2 THEN 'Penultimate State'
        ELSE 'In-Flight State'
    END AS lifecycle_position
FROM sequenced_events
ORDER BY instance_id, event_timestamp;


-- Query 1B: Top 3 Longest-Running Claims per Damage Type
WITH ranked_claims AS (
    SELECT
        damage_type,
        instance_id,
        duration_days,
        event_count,
        total_docs,
        ROW_NUMBER() OVER (
            PARTITION BY damage_type
            ORDER BY duration_days DESC, instance_id
        ) AS rank_in_category
    FROM claim_summary
)
SELECT
    damage_type,
    rank_in_category,
    instance_id,
    ROUND(duration_days::numeric, 2) AS duration_days,
    event_count,
    total_docs
FROM ranked_claims
WHERE rank_in_category <= 3
ORDER BY damage_type, rank_in_category;


-- ------------------------------------------------------------------------------
-- 2. RANK() vs. DENSE_RANK(): Evaluating Document Complexity Ties
-- ------------------------------------------------------------------------------

-- Query 2: Document Volume Ranking with Ties
-- Both ranking functions rank claims by total pages.
-- RANK() leaves gaps after ties; DENSE_RANK() does not.
SELECT
    instance_id,
    damage_type,
    total_docs,
    total_pages,
    duration_days,
    RANK() OVER (
        PARTITION BY damage_type
        ORDER BY total_pages DESC
    ) AS page_rank_with_gaps,
    DENSE_RANK() OVER (
        PARTITION BY damage_type
        ORDER BY total_pages DESC
    ) AS page_dense_rank
FROM claim_summary
WHERE damage_type = 'Animal damage'
ORDER BY total_pages DESC, total_docs DESC
LIMIT 15;


-- ------------------------------------------------------------------------------
-- 3. LAG() & LEAD(): State-to-State Transition Latency & Preceding History
-- ------------------------------------------------------------------------------

-- Query 3A: Immediate Transition Pairings and Dynamic Latency
WITH event_history AS (
    SELECT
        instance_id,
        event_timestamp,
        state_name,
        LAG(state_name) OVER w AS previous_state,
        LEAD(state_name) OVER w AS next_state,
        LAG(event_timestamp) OVER w AS previous_timestamp
    FROM process_events
    WINDOW w AS (
        PARTITION BY instance_id
        ORDER BY event_timestamp
    )
)
SELECT
    instance_id,
    event_timestamp,
    previous_state,
    state_name AS current_state,
    next_state,
    ROUND(
        (
            EXTRACT(EPOCH FROM (
                event_timestamp - previous_timestamp
            )) / 3600.0
        )::numeric,
        2
    ) AS hours_since_prior_event,
    ROUND(
        (
            EXTRACT(EPOCH FROM (
                event_timestamp - previous_timestamp
            )) / 86400.0
        )::numeric,
        3
    ) AS days_since_prior_event
FROM event_history
WHERE instance_id = 0
ORDER BY event_timestamp;


-- Query 3B: Multi-Row Lag (2-Step Preceding Workflow Context)
-- Calculate historical states across the complete event history
-- before filtering to terminal or decision-related states.
WITH event_history AS (
    SELECT
        instance_id,
        event_timestamp,
        state_name,
        type_name,
        LAG(state_name, 2) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS two_steps_prior,
        LAG(state_name, 1) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS one_step_prior
    FROM process_events
)
SELECT
    instance_id,
    event_timestamp,
    two_steps_prior,
    one_step_prior,
    state_name AS current_state,
    type_name AS damage_type
FROM event_history
WHERE state_name IN (
    'Audit passed',
    'Notification of payment',
    'Rejection'
)
ORDER BY instance_id, event_timestamp
LIMIT 15;


-- ------------------------------------------------------------------------------
-- 4. FIRST_VALUE() & LAST_VALUE(): Lifecycle Boundary Tracking
-- ------------------------------------------------------------------------------

-- Query 4: Lifecycle Boundaries and Progressive Elapsed Duration
SELECT
    instance_id,
    event_timestamp,
    state_name,
    FIRST_VALUE(state_name) OVER (
        PARTITION BY instance_id
        ORDER BY event_timestamp
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS claim_initial_state,
    LAST_VALUE(state_name) OVER (
        PARTITION BY instance_id
        ORDER BY event_timestamp
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS claim_terminal_state,
    ROUND(
        (
            EXTRACT(EPOCH FROM (
                event_timestamp -
                FIRST_VALUE(event_timestamp) OVER (
                    PARTITION BY instance_id
                    ORDER BY event_timestamp
                    ROWS BETWEEN UNBOUNDED PRECEDING
                             AND UNBOUNDED FOLLOWING
                )
            )) / 86400.0
        )::numeric,
        3
    ) AS cumulative_days_from_start
FROM process_events
WHERE instance_id IN (0, 2)
ORDER BY instance_id, event_timestamp;


-- ------------------------------------------------------------------------------
-- 5. RUNNING AGGREGATES: Cumulative Document Accumulation
-- ------------------------------------------------------------------------------

-- Query 5: Running Distinct Document Count and Page Accumulation
-- Each distinct non-null filename is counted once per claim.
WITH document_occurrences AS (
    SELECT
        instance_id,
        event_timestamp,
        state_name,
        file_name,
        COALESCE(n_pages, 0) AS event_pages,
        CASE
            WHEN file_name IS NOT NULL THEN
                ROW_NUMBER() OVER (
                    PARTITION BY instance_id, file_name
                    ORDER BY event_timestamp
                )
        END AS filename_occurrence
    FROM process_events
    WHERE instance_id IN (2, 8)
)
SELECT
    instance_id,
    event_timestamp,
    state_name,
    file_name,
    event_pages,
    SUM(
        CASE
            WHEN filename_occurrence = 1 THEN 1
            ELSE 0
        END
    ) OVER (
        PARTITION BY instance_id
        ORDER BY event_timestamp
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_distinct_docs_received,
    SUM(event_pages) OVER (
        PARTITION BY instance_id
        ORDER BY event_timestamp
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_pages_received,
    ROUND(
        (
            SUM(event_pages) OVER (
                PARTITION BY instance_id
                ORDER BY event_timestamp
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )::numeric
            /
            NULLIF(
                SUM(event_pages) OVER (
                    PARTITION BY instance_id
                ),
                0
            ) * 100
        ),
        1
    ) AS pct_of_claim_pages_delivered
FROM document_occurrences
ORDER BY instance_id, event_timestamp;


-- ------------------------------------------------------------------------------
-- 6. ROLLING & CENTERED MOVING AVERAGES
-- ------------------------------------------------------------------------------

-- Query 6: 7-Claim Centered Rolling Average of Glass Damage Cycle Times
-- The damage-type filter is applied before the window calculation.
-- Boundary rows use fewer than seven claims where necessary.
WITH glass_claims AS (
    SELECT
        instance_id,
        damage_type,
        first_event,
        duration_days
    FROM claim_summary
    WHERE damage_type = 'Glass damage'
),
rolling_metrics AS (
    SELECT
        instance_id,
        damage_type,
        first_event,
        duration_days,
        AVG(duration_days) OVER (
            ORDER BY first_event, instance_id
            ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING
        ) AS moving_avg_7_claims
    FROM glass_claims
)
SELECT
    instance_id,
    damage_type,
    first_event::date AS intake_date,
    ROUND(duration_days::numeric, 2) AS duration_days,
    ROUND(moving_avg_7_claims::numeric, 2) AS moving_avg_7_claims,
    ROUND(
        (duration_days - moving_avg_7_claims)::numeric,
        2
    ) AS deviation_from_moving_avg
FROM rolling_metrics
ORDER BY first_event, instance_id
LIMIT 20;


-- ------------------------------------------------------------------------------
-- 7. STATISTICAL DISTRIBUTIONS: NTILE, CUME_DIST & PERCENT_RANK
-- ------------------------------------------------------------------------------

-- Query 7A: Quartile Segmentation of Claims Duration
-- Q4 represents the slowest quartile, not necessarily statistical outliers.
WITH quartile_claims AS (
    SELECT
        instance_id,
        damage_type,
        duration_days,
        total_pages,
        event_count,
        NTILE(4) OVER (
            ORDER BY duration_days, instance_id
        ) AS duration_quartile
    FROM claim_summary
)
SELECT
    CASE duration_quartile
        WHEN 1 THEN 'Q1 - Fastest Quartile'
        WHEN 2 THEN 'Q2 - Second Quartile'
        WHEN 3 THEN 'Q3 - Third Quartile'
        WHEN 4 THEN 'Q4 - Slowest Quartile'
    END AS operational_speed_tier,
    COUNT(*) AS total_claims,
    ROUND(MIN(duration_days)::numeric, 2) AS min_duration_days,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(MAX(duration_days)::numeric, 2) AS max_duration_days,
    ROUND(AVG(total_pages)::numeric, 2) AS avg_pages,
    ROUND(AVG(event_count)::numeric, 2) AS avg_events
FROM quartile_claims
GROUP BY duration_quartile
ORDER BY duration_quartile;


-- Query 7B: Decile Segmentation of Documentation Intensity
WITH decile_prep AS (
    SELECT
        instance_id,
        damage_type,
        total_pages,
        duration_days,
        NTILE(10) OVER (
            ORDER BY total_pages, instance_id
        ) AS doc_volume_decile
    FROM claim_summary
)
SELECT
    doc_volume_decile,
    COUNT(*) AS claim_count,
    ROUND(MIN(total_pages)::numeric, 1) AS min_pages,
    ROUND(MAX(total_pages)::numeric, 1) AS max_pages,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days
FROM decile_prep
GROUP BY doc_volume_decile
ORDER BY doc_volume_decile;


-- Query 7C: Empirical Cumulative Distribution Function
-- PERCENT_RANK: relative rank from 0 (minimum) to 1 (maximum).
-- CUME_DIST: proportion of claims with duration less than or equal
-- to the current claim's duration.
SELECT
    instance_id,
    damage_type,
    ROUND(duration_days::numeric, 2) AS duration_days,
    ROUND(
        PERCENT_RANK() OVER (
            ORDER BY duration_days
        )::numeric,
        4
    ) AS percent_rank,
    ROUND(
        CUME_DIST() OVER (
            ORDER BY duration_days
        )::numeric,
        4
    ) AS cumulative_distribution
FROM claim_summary
ORDER BY duration_days DESC, instance_id
LIMIT 15;
