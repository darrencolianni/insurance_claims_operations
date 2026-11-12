-- ==============================================================================
-- Insurance Claims Operations Analytics - CTEs & Process Mining
-- File: sql/02_ctes_and_process_mining.sql
-- Description: Process mining workflows using Common Table Expressions (CTEs):
--              state-to-state transition matrices, bottleneck latency rankings,
--              rework/loop detection, cycle time penalties, and recursive CTEs
--              reconstructing end-to-end execution path variants.
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. MULTI-STEP PIPELINE CTE: State Transition Pairs & Latency Profiling
-- ------------------------------------------------------------------------------

-- Query 1: Detailed Transition Latency Breakdown
-- Chains 4 sequential CTEs to transform event logs into transition performance metrics.
WITH event_prep AS (
    -- Step 1: Filter and order events chronologically
    SELECT 
        instance_id,
        state_id,
        state_name,
        type_name AS damage_type,
        event_timestamp,
        ROW_NUMBER() OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS seq
    FROM process_events
),
transitions AS (
    -- Step 2: Form pairwise directed edges (Source -> Target)
    SELECT 
        instance_id,
        damage_type,
        state_name AS from_state,
        LEAD(state_name) OVER (PARTITION BY instance_id ORDER BY seq) AS to_state,
        event_timestamp AS from_time,
        LEAD(event_timestamp) OVER (PARTITION BY instance_id ORDER BY seq) AS to_time
    FROM event_prep
),
transition_intervals AS (
    -- Step 3: Compute elapsed intervals between paired states
    SELECT 
        instance_id,
        damage_type,
        from_state,
        to_state,
        ROUND((EXTRACT(EPOCH FROM (to_time - from_time)) / 3600.0)::numeric, 2) AS interval_hours,
        ROUND((EXTRACT(EPOCH FROM (to_time - from_time)) / 86400.0)::numeric, 4) AS interval_days
    FROM transitions
    WHERE to_state IS NOT NULL
)
-- Step 4: Final aggregation and operational percentiles
SELECT 
    from_state,
    to_state,
    COUNT(*) AS transition_volume,
    ROUND(AVG(interval_days)::numeric, 2) AS mean_latency_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY interval_days)::numeric, 2) AS median_latency_days,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY interval_days)::numeric, 2) AS p90_latency_days,
    ROUND(MAX(interval_days)::numeric, 2) AS max_latency_days
FROM transition_intervals
GROUP BY from_state, to_state
HAVING COUNT(*) >= 50
ORDER BY transition_volume DESC;


-- ------------------------------------------------------------------------------
-- 2. STATE TRANSITION PROBABILITY MATRIX (SQL Pivot via CTE)
-- ------------------------------------------------------------------------------

-- Query 2: Cross-Tabulated Markov State Transition Probabilities P(To | From)
-- Calculates the empirical probability of branching to each subsequent state.
WITH raw_transitions AS (
    SELECT 
        state_name AS from_state,
        LEAD(state_name) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS to_state
    FROM process_events
),
clean_transitions AS (
    SELECT from_state, to_state
    FROM raw_transitions
    WHERE to_state IS NOT NULL
),
transition_totals AS (
    SELECT 
        from_state,
        COUNT(*) AS total_departures
    FROM clean_transitions
    GROUP BY from_state
)
SELECT 
    t.from_state,
    t.total_departures,
    ROUND((COUNT(CASE WHEN c.to_state = 'Processing' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Processing %",
    ROUND((COUNT(CASE WHEN c.to_state = 'Document request' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Doc Request %",
    ROUND((COUNT(CASE WHEN c.to_state = 'Damage documents' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Damage Docs %",
    ROUND((COUNT(CASE WHEN c.to_state = 'Notification of payment' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Payment %",
    ROUND((COUNT(CASE WHEN c.to_state = 'Audit passed' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Audit Passed %",
    ROUND((COUNT(CASE WHEN c.to_state = 'Further inquiry' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Further Inquiry %",
    ROUND((COUNT(CASE WHEN c.to_state = 'Rejection' THEN 1 END)::numeric / t.total_departures * 100), 1) AS "-> Rejection %"
FROM clean_transitions c
JOIN transition_totals t ON c.from_state = t.from_state
GROUP BY t.from_state, t.total_departures
ORDER BY t.total_departures DESC;


-- ------------------------------------------------------------------------------
-- 3. PROCESS BOTTLENECK IDENTIFIER CTE
-- ------------------------------------------------------------------------------

-- Query 3: Top Bottleneck Transitions Ranked by Portfolio Wait-Time Impact
-- Calculates cumulative days spent across all claims in each specific transition.
WITH ranked_bottlenecks AS (
    SELECT 
        state_name AS from_state,
        LEAD(state_name) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS to_state,
        EXTRACT(EPOCH FROM (
            LEAD(event_timestamp) OVER (PARTITION BY instance_id ORDER BY event_timestamp) - event_timestamp
        )) / 86400.0 AS duration_days
    FROM process_events
)
SELECT 
    from_state || '  -->  ' || to_state AS workflow_transition,
    COUNT(*) AS occurrences,
    ROUND(SUM(duration_days)::numeric, 1) AS cumulative_portfolio_days,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_turnaround_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_turnaround_days,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS p95_turnaround_days,
    -- Percentage of total portfolio lifecycle wait time consumed by this transition
    ROUND((SUM(duration_days) / (SELECT SUM(duration_days) FROM claim_summary) * 100.0)::numeric, 2) AS pct_of_portfolio_cycle_time
FROM ranked_bottlenecks
WHERE to_state IS NOT NULL
GROUP BY from_state, to_state
ORDER BY cumulative_portfolio_days DESC
LIMIT 10;


-- ------------------------------------------------------------------------------
-- 4. PROCESS REWORK & LOOP DETECTION CTE
-- ------------------------------------------------------------------------------

-- Query 4: Identification of Claims Experiencing Rework and Cycle-Time Penalties
-- Flags claims that re-enter stages (such as multiple 'Processing' or repeated 'Document request' states).
WITH state_counts_per_claim AS (
    SELECT 
        instance_id,
        state_name,
        COUNT(*) AS visits_to_state
    FROM process_events
    GROUP BY instance_id, state_name
),
rework_flags AS (
    SELECT 
        instance_id,
        MAX(CASE WHEN visits_to_state > 1 THEN 1 ELSE 0 END) AS has_any_rework,
        MAX(CASE WHEN state_name = 'Processing' AND visits_to_state > 1 THEN 1 ELSE 0 END) AS has_reprocessing,
        MAX(CASE WHEN state_name = 'Document request' AND visits_to_state > 1 THEN 1 ELSE 0 END) AS has_repeat_doc_requests,
        MAX(CASE WHEN state_name = 'Further inquiry' AND visits_to_state > 1 THEN 1 ELSE 0 END) AS has_multiple_inquiries
    FROM state_counts_per_claim
    GROUP BY instance_id
),
rework_joined AS (
    SELECT 
        cs.instance_id,
        cs.damage_type,
        cs.duration_days,
        cs.event_count,
        cs.total_pages,
        COALESCE(rf.has_any_rework, 0) AS has_rework,
        COALESCE(rf.has_reprocessing, 0) AS has_reprocessing,
        COALESCE(rf.has_repeat_doc_requests, 0) AS has_repeat_doc_requests
    FROM claim_summary cs
    LEFT JOIN rework_flags rf ON cs.instance_id = rf.instance_id
)
SELECT 
    CASE WHEN has_rework = 1 THEN 'Rework / Loops Present' ELSE 'Clean Linear Flow' END AS workflow_category,
    COUNT(*) AS claim_count,
    ROUND((COUNT(*)::numeric / (SELECT COUNT(*) FROM claim_summary) * 100.0), 1) AS pct_of_claims,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days,
    ROUND(AVG(event_count)::numeric, 1) AS avg_touchpoints,
    ROUND(AVG(total_pages)::numeric, 1) AS avg_pages
FROM rework_joined
GROUP BY has_rework
ORDER BY has_rework DESC;


-- ------------------------------------------------------------------------------
-- 5. RECURSIVE CTE: End-to-End Workflow Path Reconstruction
-- ------------------------------------------------------------------------------

-- Query 5: Reconstructing Full Execution Paths (Process Variants)
-- Traces state sequences across events to identify standard operating paths vs anomalies.
WITH RECURSIVE claim_event_numbered AS (
    SELECT 
        instance_id,
        state_name,
        ROW_NUMBER() OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS step_num
    FROM process_events
),
path_builder AS (
    -- Anchor member: Initial recorded event (step 1)
    SELECT 
        instance_id,
        step_num,
        CAST(state_name AS TEXT) AS execution_path
    FROM claim_event_numbered
    WHERE step_num = 1

    UNION ALL

    -- Recursive member: Appends subsequent steps
    SELECT 
        next_event.instance_id,
        next_event.step_num,
        pb.execution_path || ' -> ' || next_event.state_name
    FROM path_builder pb
    JOIN claim_event_numbered next_event 
      ON pb.instance_id = next_event.instance_id 
     AND next_event.step_num = pb.step_num + 1
    WHERE pb.step_num < 15 -- Bounded depth for process logs
),
terminal_paths AS (
    SELECT 
        pb.instance_id,
        pb.execution_path,
        pb.step_num,
        cs.damage_type,
        cs.duration_days,
        ROW_NUMBER() OVER (PARTITION BY pb.instance_id ORDER BY pb.step_num DESC) AS is_terminal_row
    FROM path_builder pb
    JOIN claim_summary cs ON pb.instance_id = cs.instance_id
)
SELECT 
    execution_path,
    COUNT(*) AS frequency,
    ROUND((COUNT(*)::numeric / (SELECT COUNT(*) FROM claim_summary) * 100.0), 2) AS pct_of_portfolio,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_lifecycle_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_lifecycle_days
FROM terminal_paths
WHERE is_terminal_row = 1
GROUP BY execution_path
ORDER BY frequency DESC
LIMIT 10;


-- ------------------------------------------------------------------------------
-- 6. STRAIGHT-THROUGH PROCESSING (STP) CANDIDATE ANALYSIS CTE
-- ------------------------------------------------------------------------------

-- Query 6: Identifying Straight-Through Processing (STP) / Low-Touch Claims
-- Low touch claims: <= 4 events, no inquiries or rejections, ending in payment or audit pass.
WITH claim_profile AS (
    SELECT 
        cs.instance_id,
        cs.damage_type,
        cs.event_count,
        cs.total_docs,
        cs.duration_days,
        cs.last_state,
        -- Check for presence of friction stages
        MAX(CASE WHEN pe.state_name IN ('Document request', 'Further inquiry', 'Rejection') THEN 1 ELSE 0 END) AS had_friction
    FROM claim_summary cs
    JOIN process_events pe ON cs.instance_id = pe.instance_id
    GROUP BY cs.instance_id, cs.damage_type, cs.event_count, cs.total_docs, cs.duration_days, cs.last_state
)
SELECT 
    damage_type,
    COUNT(*) AS total_claims,
    COUNT(CASE WHEN had_friction = 0 AND event_count <= 4 AND last_state IN ('Notification of payment', 'Audit passed') THEN 1 END) AS stp_eligible_claims,
    ROUND((
        COUNT(CASE WHEN had_friction = 0 AND event_count <= 4 AND last_state IN ('Notification of payment', 'Audit passed') THEN 1 END)::numeric 
        / COUNT(*) * 100.0
    ), 1) AS stp_rate_pct,
    ROUND(AVG(CASE WHEN had_friction = 0 AND event_count <= 4 THEN duration_days END)::numeric, 2) AS stp_avg_duration_days,
    ROUND(AVG(CASE WHEN had_friction = 1 OR event_count > 4 THEN duration_days END)::numeric, 2) AS manual_avg_duration_days
FROM claim_profile
GROUP BY damage_type
ORDER BY total_claims DESC;
