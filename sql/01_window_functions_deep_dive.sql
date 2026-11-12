-- ==============================================================================
-- Insurance Claims Operations Analytics - Window Functions Deep Dive
-- File: sql/01_window_functions_deep_dive.sql
-- Description: Comprehensive showcase of advanced SQL window functions applied
--              to insurance claims operations: ranking, lead/lag transitions,
--              first/last value frames, running aggregates, moving averages,
--              and statistical distribution functions (NTILE, CUME_DIST, PERCENT_RANK).
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ROW_NUMBER(): Chronological Sequencing & Top-N Per Category
-- ------------------------------------------------------------------------------

-- Query 1A: Chronological and Reverse Event Sequence Numbers per Claim
-- Helps identify the exact sequence of events, initial touchpoint, and terminal stages.
SELECT 
    instance_id,
    event_timestamp,
    state_name,
    type_name AS damage_type,
    ROW_NUMBER() OVER (
        PARTITION BY instance_id 
        ORDER BY event_timestamp ASC
    ) AS event_seq_asc,
    ROW_NUMBER() OVER (
        PARTITION BY instance_id 
        ORDER BY event_timestamp DESC
    ) AS event_seq_desc,
    -- Flagging the final event and penultimate event
    CASE 
        WHEN ROW_NUMBER() OVER (PARTITION BY instance_id ORDER BY event_timestamp DESC) = 1 THEN 'Final State'
        WHEN ROW_NUMBER() OVER (PARTITION BY instance_id ORDER BY event_timestamp DESC) = 2 THEN 'Penultimate State'
        ELSE 'In-Flight State'
    END AS lifecycle_position
FROM process_events
WHERE instance_id IN (0, 1, 2, 9)
ORDER BY instance_id, event_timestamp;


-- Query 1B: Top 3 Longest-Running Claims per Damage Type (Partitioned Top-N)
WITH ranked_claims AS (
    SELECT 
        damage_type,
        instance_id,
        first_event,
        last_event,
        duration_days,
        event_count,
        total_docs,
        ROW_NUMBER() OVER (
            PARTITION BY damage_type 
            ORDER BY duration_days DESC
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
-- Demonstrates differences between RANK() (leaves gaps after ties) and DENSE_RANK() (consecutive integers).
SELECT 
    instance_id,
    damage_type,
    total_docs,
    total_pages,
    duration_days,
    RANK() OVER (
        PARTITION BY damage_type 
        ORDER BY total_pages DESC, total_docs DESC
    ) AS page_rank_with_gaps,
    DENSE_RANK() OVER (
        PARTITION BY damage_type 
        ORDER BY total_pages DESC, total_docs DESC
    ) AS page_dense_rank
FROM claim_summary
WHERE damage_type = 'Animal damage'
ORDER BY total_pages DESC, total_docs DESC
LIMIT 15;


-- ------------------------------------------------------------------------------
-- 3. LAG() & LEAD(): State-to-State Transition Latency & Preceding History
-- ------------------------------------------------------------------------------

-- Query 3A: Immediate Transition Pairings and Dynamic Latency Calculation
-- Computes the prior state, next state, and exact elapsed interval (in hours and days).
SELECT 
    instance_id,
    event_timestamp,
    LAG(state_name, 1) OVER w AS previous_state,
    state_name AS current_state,
    LEAD(state_name, 1) OVER w AS next_state,
    -- Dynamic turnaround interval between consecutive events
    ROUND(
        (EXTRACT(EPOCH FROM (event_timestamp - LAG(event_timestamp, 1) OVER w)) / 3600.0)::numeric, 
        2
    ) AS hours_since_prior_event,
    ROUND(
        (EXTRACT(EPOCH FROM (event_timestamp - LAG(event_timestamp, 1) OVER w)) / 86400.0)::numeric, 
        3
    ) AS days_since_prior_event
FROM process_events
WHERE instance_id = 0
WINDOW w AS (PARTITION BY instance_id ORDER BY event_timestamp);


-- Query 3B: Multi-Row Lag (2-Step Preceding Workflow Context)
-- Identifies actions taken 2 steps prior to evaluate rework or verification triggers.
SELECT 
    instance_id,
    event_timestamp,
    LAG(state_name, 2) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS two_steps_prior,
    LAG(state_name, 1) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS one_step_prior,
    state_name AS current_state,
    type_name AS damage_type
FROM process_events
WHERE state_name IN ('Audit passed', 'Notification of payment', 'Rejection')
ORDER BY instance_id, event_timestamp
LIMIT 15;


-- ------------------------------------------------------------------------------
-- 4. FIRST_VALUE() & LAST_VALUE(): Lifecycle Boundary Tracking & Cumulative Elapsed Days
-- ------------------------------------------------------------------------------

-- Query 4: Lifecycle Boundaries and Progressive Elapsed Duration
-- Note: LAST_VALUE() requires explicit window frame (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
-- or (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) to avoid stopping at CURRENT ROW.
SELECT 
    instance_id,
    event_timestamp,
    state_name,
    -- First recorded stage of claim
    FIRST_VALUE(state_name) OVER (
        PARTITION BY instance_id 
        ORDER BY event_timestamp 
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS claim_initial_state,
    -- Final recorded outcome stage of claim
    LAST_VALUE(state_name) OVER (
        PARTITION BY instance_id 
        ORDER BY event_timestamp 
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS claim_terminal_state,
    -- Cumulative elapsed days from claim inception to current event
    ROUND(
        (EXTRACT(EPOCH FROM (
            event_timestamp - FIRST_VALUE(event_timestamp) OVER (
                PARTITION BY instance_id 
                ORDER BY event_timestamp 
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            )
        )) / 86400.0)::numeric,
        3
    ) AS cumulative_days_from_start
FROM process_events
WHERE instance_id IN (0, 2)
ORDER BY instance_id, event_timestamp;


-- ------------------------------------------------------------------------------
-- 5. RUNNING AGGREGATES: Cumulative Document Accumulation Over Lifecycle
-- ------------------------------------------------------------------------------

-- Query 5: Running Total of Documents and Pages Submitted
-- Evaluates documentation burden as it accrues step-by-step.
SELECT 
    instance_id,
    event_timestamp,
    state_name,
    file_name,
    COALESCE(n_pages, 0) AS event_pages,
    -- Cumulative document count
    COUNT(file_name) OVER (
        PARTITION BY instance_id 
        ORDER BY event_timestamp 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_docs_received,
    -- Cumulative document pages
    SUM(COALESCE(n_pages, 0)) OVER (
        PARTITION BY instance_id 
        ORDER BY event_timestamp 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_pages_received,
    -- Proportion of total claim pages delivered by this step
    ROUND(
        (
            SUM(COALESCE(n_pages, 0)) OVER (
                PARTITION BY instance_id 
                ORDER BY event_timestamp 
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) / NULLIF(
                SUM(COALESCE(n_pages, 0)) OVER (
                    PARTITION BY instance_id
                ), 0
            ) * 100.0
        )::numeric, 
        1
    ) AS pct_of_claim_pages_delivered
FROM process_events
WHERE instance_id IN (2, 8)
ORDER BY instance_id, event_timestamp;


-- ------------------------------------------------------------------------------
-- 6. ROLLING & CENTERED MOVING AVERAGES: Smoothing Operational Volatility
-- ------------------------------------------------------------------------------

-- Query 6: 7-Claim Centered Rolling Average of Cycle Times
-- Smooths claim-by-claim noise to evaluate local operational velocity trends.
SELECT 
    instance_id,
    damage_type,
    first_event::DATE AS intake_date,
    ROUND(duration_days::numeric, 2) AS duration_days,
    -- Preceding 3 + Current + Following 3 claims moving average
    ROUND(
        AVG(duration_days) OVER (
            ORDER BY first_event 
            ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING
        )::numeric, 
        2
    ) AS moving_avg_7_claims,
    -- Deviation of current claim from local rolling average
    ROUND(
        (duration_days - AVG(duration_days) OVER (
            ORDER BY first_event 
            ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING
        ))::numeric, 
        2
    ) AS deviation_from_moving_avg
FROM claim_summary
WHERE damage_type = 'Glass damage'
ORDER BY first_event
LIMIT 20;


-- ------------------------------------------------------------------------------
-- 7. STATISTICAL DISTRIBUTIONS: NTILE, CUME_DIST & PERCENT_RANK
-- ------------------------------------------------------------------------------

-- Query 7A: Quartile Segmentation (NTILE) for Claims Duration Triage
-- Segregates claims into Fast-track (Q1), Standard (Q2), Extended (Q3), and Protracted (Q4).
WITH quartile_claims AS (
    SELECT 
        instance_id,
        damage_type,
        duration_days,
        total_pages,
        event_count,
        NTILE(4) OVER (ORDER BY duration_days ASC) AS duration_quartile
    FROM claim_summary
)
SELECT 
    CASE duration_quartile
        WHEN 1 THEN 'Q1 - Fast Track (<= 25%)'
        WHEN 2 THEN 'Q2 - Standard (25% - 50%)'
        WHEN 3 THEN 'Q3 - Extended (50% - 75%)'
        WHEN 4 THEN 'Q4 - Protracted / Outlier (> 75%)'
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


-- Query 7B: Decile Segmentation (NTILE(10)) of Documentation Intensity
WITH decile_prep AS (
    SELECT 
        instance_id,
        damage_type,
        total_pages,
        duration_days,
        NTILE(10) OVER (ORDER BY total_pages ASC) AS doc_volume_decile
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


-- Query 7C: Empirical Cumulative Distribution Function (CUME_DIST & PERCENT_RANK)
-- Shows exactly where an individual claim falls relative to the entire company distribution.
SELECT 
    instance_id,
    damage_type,
    ROUND(duration_days::numeric, 2) AS duration_days,
    -- Relative rank from 0.0 (fastest) to 1.0 (slowest)
    ROUND(PERCENT_RANK() OVER (ORDER BY duration_days)::numeric, 4) AS percent_rank,
    -- Proportion of all claims with duration less than or equal to current row
    ROUND(CUME_DIST() OVER (ORDER BY duration_days)::numeric, 4) AS cumulative_distribution
FROM claim_summary
ORDER BY duration_days DESC
LIMIT 15;
