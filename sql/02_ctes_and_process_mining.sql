
-- ==============================================================================
-- Insurance Claims Operations Analytics - CTEs & Process Mining
-- File: sql/02_ctes_and_process_mining.sql
-- Description: Process mining workflows using Common Table Expressions (CTEs):
--              state transition analysis, bottleneck latency rankings,
--              repeated-state detection, recursive workflow reconstruction,
--              and straight-through processing (STP) candidate analysis.
-- Target DB: PostgreSQL 14+
-- ==============================================================================


-- ------------------------------------------------------------------------------
-- 1. STATE TRANSITION PAIRS & LATENCY PROFILING
-- ------------------------------------------------------------------------------

-- Query 1: Detailed Transition Latency Breakdown
-- Calculates elapsed time between consecutive events and summarizes
-- transition volume, mean, median, 90th percentile, and maximum latency.
WITH transitions AS (
    SELECT
        instance_id,
        state_name AS from_state,
        LEAD(state_name) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS to_state,
        event_timestamp AS from_time,
        LEAD(event_timestamp) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS to_time
    FROM process_events
),
transition_intervals AS (
    SELECT
        from_state,
        to_state,
        EXTRACT(EPOCH FROM (to_time - from_time)) / 86400.0
            AS interval_days
    FROM transitions
    WHERE to_state IS NOT NULL
)
SELECT
    from_state,
    to_state,
    COUNT(*) AS transition_volume,
    ROUND(AVG(interval_days)::numeric, 2) AS mean_latency_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY interval_days)::numeric,
        2
    ) AS median_latency_days,
    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP (ORDER BY interval_days)::numeric,
        2
    ) AS p90_latency_days,
    ROUND(MAX(interval_days)::numeric, 2) AS max_latency_days
FROM transition_intervals
GROUP BY from_state, to_state
HAVING COUNT(*) >= 50
ORDER BY transition_volume DESC;


-- ------------------------------------------------------------------------------
-- 2. STATE TRANSITION PROBABILITY MATRIX
-- ------------------------------------------------------------------------------

-- Query 2: Selected State Transition Probabilities P(To | From)
-- Percentages use ALL departures from each source state as the denominator.
-- Only the seven listed destination states are displayed; therefore,
-- displayed percentages may not sum to 100%.
WITH transitions AS (
    SELECT
        state_name AS from_state,
        LEAD(state_name) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS to_state
    FROM process_events
),
valid_transitions AS (
    SELECT
        from_state,
        to_state
    FROM transitions
    WHERE to_state IS NOT NULL
)
SELECT
    from_state,
    COUNT(*) AS total_departures,
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Processing'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Processing %",
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Document request'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Doc Request %",
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Damage documents'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Damage Docs %",
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Notification of payment'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Payment %",
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Audit passed'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Audit Passed %",
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Further inquiry'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Further Inquiry %",
    ROUND(
        COUNT(*) FILTER (
            WHERE to_state = 'Rejection'
        )::numeric / COUNT(*) * 100,
        1
    ) AS "-> Rejection %"
FROM valid_transitions
GROUP BY from_state
ORDER BY total_departures DESC;


-- ------------------------------------------------------------------------------
-- 3. PROCESS BOTTLENECK IDENTIFICATION
-- ------------------------------------------------------------------------------

-- Query 3: Top Bottleneck Transitions Ranked by Portfolio Wait-Time Impact
-- Compares the total time spent in each transition against total claim
-- lifecycle time across the portfolio.
WITH transitions AS (
    SELECT
        state_name AS from_state,
        LEAD(state_name) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS to_state,
        event_timestamp AS from_time,
        LEAD(event_timestamp) OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS to_time
    FROM process_events
),
transition_intervals AS (
    SELECT
        from_state,
        to_state,
        EXTRACT(EPOCH FROM (to_time - from_time)) / 86400.0
            AS duration_days
    FROM transitions
    WHERE to_state IS NOT NULL
),
portfolio_total AS (
    SELECT SUM(duration_days) AS total_portfolio_days
    FROM claim_summary
)
SELECT
    from_state || '  -->  ' || to_state AS workflow_transition,
    COUNT(*) AS occurrences,
    ROUND(SUM(duration_days)::numeric, 1)
        AS cumulative_portfolio_days,
    ROUND(AVG(duration_days)::numeric, 2)
        AS avg_turnaround_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS median_turnaround_days,
    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS p95_turnaround_days,
    ROUND(
        (
            SUM(duration_days)
            / NULLIF(MAX(pt.total_portfolio_days), 0)
            * 100
        )::numeric,
        2
    ) AS pct_of_portfolio_cycle_time
FROM transition_intervals ti
CROSS JOIN portfolio_total pt
GROUP BY from_state, to_state
ORDER BY cumulative_portfolio_days DESC
LIMIT 10;


-- ------------------------------------------------------------------------------
-- 4. REPEATED-STATE VISIT ANALYSIS
-- ------------------------------------------------------------------------------

-- Query 4: Claims with Repeated Workflow States
-- A state visited more than once is flagged as a repeated-state visit.
-- This is a potential rework indicator, not definitive proof of rework.
WITH state_counts AS (
    SELECT
        instance_id,
        state_name,
        COUNT(*) AS visits_to_state
    FROM process_events
    GROUP BY instance_id, state_name
),
claim_flags AS (
    SELECT
        instance_id,
        MAX(
            CASE WHEN visits_to_state > 1 THEN 1 ELSE 0 END
        ) AS has_repeated_state
    FROM state_counts
    GROUP BY instance_id
),
claim_profiles AS (
    SELECT
        cs.instance_id,
        cs.duration_days,
        cs.event_count,
        cs.total_pages,
        COALESCE(cf.has_repeated_state, 0) AS has_repeated_state
    FROM claim_summary cs
    LEFT JOIN claim_flags cf
        ON cs.instance_id = cf.instance_id
)
SELECT
    CASE
        WHEN has_repeated_state = 1
            THEN 'Repeated State Visits'
        ELSE 'No Repeated State Visits'
    END AS workflow_category,
    COUNT(*) AS claim_count,
    ROUND(
        COUNT(*)::numeric
        / NULLIF((SELECT COUNT(*) FROM claim_summary), 0)
        * 100,
        1
    ) AS pct_of_claims,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS median_duration_days,
    ROUND(AVG(event_count)::numeric, 1) AS avg_touchpoints,
    ROUND(AVG(total_pages)::numeric, 1) AS avg_pages
FROM claim_profiles
GROUP BY has_repeated_state
ORDER BY has_repeated_state DESC;


-- ------------------------------------------------------------------------------
-- 5. RECURSIVE CTE: END-TO-END WORKFLOW PATH RECONSTRUCTION
-- ------------------------------------------------------------------------------

-- Query 5: Reconstructing Complete Execution Paths (Process Variants)
-- Recursively appends each claim's events in chronological order.
-- No arbitrary recursion limit is imposed.
WITH RECURSIVE claim_event_numbered AS (
    SELECT
        instance_id,
        state_name,
        ROW_NUMBER() OVER (
            PARTITION BY instance_id
            ORDER BY event_timestamp
        ) AS step_num
    FROM process_events
),
path_builder AS (
    -- Anchor: first event for each claim.
    SELECT
        instance_id,
        step_num,
        CAST(state_name AS text) AS execution_path
    FROM claim_event_numbered
    WHERE step_num = 1

    UNION ALL

    -- Recursive member: append the next chronological event.
    SELECT
        next_event.instance_id,
        next_event.step_num,
        pb.execution_path || ' -> ' || next_event.state_name
    FROM path_builder pb
    JOIN claim_event_numbered next_event
        ON pb.instance_id = next_event.instance_id
       AND next_event.step_num = pb.step_num + 1
),
terminal_paths AS (
    SELECT
        pb.instance_id,
        pb.execution_path,
        cs.duration_days
    FROM path_builder pb
    JOIN claim_summary cs
        ON pb.instance_id = cs.instance_id
    WHERE pb.step_num = (
        SELECT MAX(ce.step_num)
        FROM claim_event_numbered ce
        WHERE ce.instance_id = pb.instance_id
    )
)
SELECT
    execution_path,
    COUNT(*) AS frequency,
    ROUND(
        COUNT(*)::numeric
        / NULLIF((SELECT COUNT(*) FROM claim_summary), 0)
        * 100,
        2
    ) AS pct_of_portfolio,
    ROUND(AVG(duration_days)::numeric, 2)
        AS avg_lifecycle_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS median_lifecycle_days
FROM terminal_paths
GROUP BY execution_path
ORDER BY frequency DESC
LIMIT 10;


-- ------------------------------------------------------------------------------
-- 6. STRAIGHT-THROUGH PROCESSING (STP) CANDIDATE ANALYSIS
-- ------------------------------------------------------------------------------

-- Query 6: Identifying STP-Eligible and Non-Eligible Claims
-- STP is an analyst-defined proxy (the data source doesn't have, for instance, qualities which may relate to former, confirmed STP claims):
--   1. Four or fewer recorded events.
--   2. No document requests, further inquiries, or rejections.
--   3. Terminal state is Notification of payment or Audit passed.
-- This dataset does not establish whether a claim was truly automated.
WITH claim_friction AS (
    SELECT
        instance_id,
        MAX(
            CASE
                WHEN state_name IN (
                    'Document request',
                    'Further inquiry',
                    'Rejection'
                ) THEN 1
                ELSE 0
            END
        ) AS had_friction
    FROM process_events
    GROUP BY instance_id
),
claim_profile AS (
    SELECT
        cs.instance_id,
        cs.damage_type,
        cs.event_count,
        cs.duration_days,
        cs.last_state,
        COALESCE(cf.had_friction, 0) AS had_friction,
        CASE
            WHEN COALESCE(cf.had_friction, 0) = 0
             AND cs.event_count <= 4
             AND cs.last_state IN (
                 'Notification of payment',
                 'Audit passed'
             )
            THEN 1
            ELSE 0
        END AS is_stp_eligible
    FROM claim_summary cs
    LEFT JOIN claim_friction cf
        ON cs.instance_id = cf.instance_id
)
SELECT
    damage_type,
    COUNT(*) AS total_claims,
    COUNT(*) FILTER (
        WHERE is_stp_eligible = 1
    ) AS stp_eligible_claims,
    ROUND(
        COUNT(*) FILTER (
            WHERE is_stp_eligible = 1
        )::numeric
        / NULLIF(COUNT(*), 0)
        * 100,
        1
    ) AS stp_rate_pct,
    ROUND(
        AVG(duration_days) FILTER (
            WHERE is_stp_eligible = 1
        )::numeric,
        2
    ) AS stp_avg_duration_days,
    ROUND(
        AVG(duration_days) FILTER (
            WHERE is_stp_eligible = 0
        )::numeric,
        2
    ) AS non_stp_avg_duration_days
FROM claim_profile
GROUP BY damage_type
ORDER BY total_claims DESC;
