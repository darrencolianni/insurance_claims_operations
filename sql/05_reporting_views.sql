-- ==============================================================================
-- Insurance Claims Operations Analytics - Semantic Reporting Views & Data Marts
-- File: sql/05_reporting_views.sql
-- Description: Semantic reporting layer and modular analytical views designed
--              for executive dashboards and BI consumption (Power BI / Tableau).
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. VIEW: v_process_transitions (Event-Level Transition Fact Mart)
-- ------------------------------------------------------------------------------
-- Granularity: One row per sequential state transition.
CREATE OR REPLACE VIEW v_process_transitions AS
WITH event_sequenced AS (
    SELECT 
        instance_id,
        event_timestamp,
        state_id,
        state_name,
        type_id AS damage_type_id,
        type_name AS damage_type,
        file_name,
        COALESCE(n_pages, 0) AS n_pages,
        ROW_NUMBER() OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS step_number,
        LEAD(state_id) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS next_state_id,
        LEAD(state_name) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS next_state_name,
        LEAD(event_timestamp) OVER (PARTITION BY instance_id ORDER BY event_timestamp) AS next_event_timestamp
    FROM process_events
)
SELECT 
    es.instance_id,
    es.step_number AS transition_seq,
    es.damage_type,
    es.state_name AS from_state,
    s1.phase_category AS from_phase,
    es.next_state_name AS to_state,
    s2.phase_category AS to_phase,
    es.event_timestamp AS transition_start,
    es.next_event_timestamp AS transition_end,
    -- Transition Duration
    ROUND((EXTRACT(EPOCH FROM (es.next_event_timestamp - es.event_timestamp)))::numeric, 0) AS interval_seconds,
    ROUND((EXTRACT(EPOCH FROM (es.next_event_timestamp - es.event_timestamp)) / 3600.0)::numeric, 2) AS interval_hours,
    ROUND((EXTRACT(EPOCH FROM (es.next_event_timestamp - es.event_timestamp)) / 86400.0)::numeric, 4) AS interval_days,
    -- Flag backward loops / rework
    CASE 
        WHEN es.state_name IN ('Damage documents', 'Document request', 'Further inquiry') 
         AND es.next_state_name = 'Processing' THEN TRUE
        WHEN es.state_name = es.next_state_name THEN TRUE
        ELSE FALSE
    END AS is_rework_loop
FROM event_sequenced es
JOIN dim_process_state s1 ON es.state_id = s1.state_id
JOIN dim_process_state s2 ON es.next_state_id = s2.state_id
WHERE es.next_state_name IS NOT NULL;

COMMENT ON VIEW v_process_transitions IS 'Fact view containing every observed process transition, turnaround time, and rework indicators.';


-- ------------------------------------------------------------------------------
-- 2. VIEW: v_claim_master (Enriched Claim Entity Dimension)
-- ------------------------------------------------------------------------------
-- Granularity: One row per insurance claim (5,131 claims).
CREATE OR REPLACE VIEW v_claim_master AS
WITH claim_rework_calc AS (
    SELECT 
        instance_id,
        CASE WHEN COUNT(*) > COUNT(DISTINCT state_name) THEN TRUE ELSE FALSE END AS has_rework_loop
    FROM process_events
    GROUP BY instance_id
),
first_doc_calc AS (
    SELECT 
        instance_id,
        MIN(event_timestamp) AS first_doc_timestamp
    FROM process_events
    WHERE file_name IS NOT NULL
    GROUP BY instance_id
)
SELECT 
    cs.instance_id,
    cs.damage_type,
    dt.complexity_tier,
    cs.first_event AS intake_timestamp,
    cs.first_event::DATE AS intake_date,
    TO_CHAR(cs.first_event, 'YYYY-MM') AS intake_year_month,
    TO_CHAR(cs.first_event, 'Dy') AS intake_day_of_week,
    cs.last_event AS closure_timestamp,
    cs.first_state,
    cs.last_state,
    cs.event_count AS touchpoints_count,
    cs.total_docs,
    COALESCE(cs.total_pages, 0) AS total_pages,
    ROUND(cs.duration_days::numeric, 2) AS lifecycle_duration_days,
    cs.page_bracket,
    -- Operational Aging Category
    CASE 
        WHEN cs.duration_days < 1.0 THEN 'Same-Day (< 24h)'
        WHEN cs.duration_days < 3.0 THEN 'Fast-Track (1-3d)'
        WHEN cs.duration_days < 7.0 THEN 'Target SLA (3-7d)'
        WHEN cs.duration_days < 14.0 THEN 'Delayed (7-14d)'
        WHEN cs.duration_days < 30.0 THEN 'Extended (14-30d)'
        WHEN cs.duration_days < 90.0 THEN 'Severely Delayed (30-90d)'
        ELSE 'Stalled (> 90d)'
    END AS aging_bracket,
    -- Duration Quartile Tier
    CASE NTILE(4) OVER (ORDER BY cs.duration_days ASC)
        WHEN 1 THEN 'Q1 - Express'
        WHEN 2 THEN 'Q2 - Standard'
        WHEN 3 THEN 'Q3 - Elevated'
        WHEN 4 THEN 'Q4 - Protracted'
    END AS duration_speed_quartile,
    -- Straight-Through Processing (STP) Eligibility
    CASE 
        WHEN cs.event_count <= 4 
         AND cs.last_state IN ('Notification of payment', 'Audit passed')
         AND COALESCE(rw.has_rework_loop, FALSE) = FALSE 
        THEN TRUE 
        ELSE FALSE 
    END AS is_stp_compliant,
    -- Rework / Loop Flag
    COALESCE(rw.has_rework_loop, FALSE) AS has_rework_loop,
    -- Interval from claim intake to first digital document upload (in days)
    ROUND((EXTRACT(EPOCH FROM (fd.first_doc_timestamp - cs.first_event)) / 86400.0)::numeric, 2) AS days_to_first_doc
FROM claim_summary cs
LEFT JOIN dim_damage_type dt ON cs.damage_type = dt.damage_type_name
LEFT JOIN claim_rework_calc rw ON cs.instance_id = rw.instance_id
LEFT JOIN first_doc_calc fd ON cs.instance_id = fd.instance_id;

COMMENT ON VIEW v_claim_master IS 'Comprehensive analytical claim master view enriched with operational classifications, STP flags, and rework tags.';


-- ------------------------------------------------------------------------------
-- 3. VIEW: v_transition_bottlenecks (Ranked Bottleneck Scorecard)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_transition_bottlenecks AS
SELECT 
    from_state,
    to_state,
    from_state || ' -> ' || to_state AS transition_label,
    COUNT(*) AS transition_count,
    ROUND(SUM(interval_days)::numeric, 1) AS total_wait_days,
    ROUND(AVG(interval_days)::numeric, 2) AS avg_turnaround_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY interval_days)::numeric, 2) AS median_turnaround_days,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY interval_days)::numeric, 2) AS p90_turnaround_days,
    ROUND(MAX(interval_days)::numeric, 2) AS max_turnaround_days,
    CASE 
        WHEN PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY interval_days) >= 5.0 THEN 'Critical Bottleneck'
        WHEN PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY interval_days) >= 1.0 THEN 'Moderate Delay'
        ELSE 'Fluid Transition'
    END AS bottleneck_severity
FROM v_process_transitions
GROUP BY from_state, to_state
ORDER BY total_wait_days DESC;

COMMENT ON VIEW v_transition_bottlenecks IS 'Aggregated operational transition scorecard ranking process bottlenecks by portfolio latency.';


-- ------------------------------------------------------------------------------
-- 4. VIEW: v_damage_scorecard (Executive Category Scorecard)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_damage_scorecard AS
SELECT 
    cm.damage_type,
    dt.complexity_tier,
    COUNT(*) AS total_claims,
    ROUND((COUNT(*)::numeric / (SELECT COUNT(*) FROM claim_summary) * 100.0), 1) AS portfolio_share_pct,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cm.lifecycle_duration_days)::numeric, 2) AS median_duration_days,
    ROUND(AVG(cm.lifecycle_duration_days)::numeric, 2) AS mean_duration_days,
    -- Interquartile Range
    ROUND(
        (PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY cm.lifecycle_duration_days) 
         - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY cm.lifecycle_duration_days))::numeric, 
        2
    ) AS iqr_duration_days,
    -- Straight-Through Processing Rate
    ROUND((COUNT(*) FILTER (WHERE cm.is_stp_compliant = TRUE)::numeric / COUNT(*) * 100.0), 1) AS stp_rate_pct,
    -- Rework Loop Incidence Rate
    ROUND((COUNT(*) FILTER (WHERE cm.has_rework_loop = TRUE)::numeric / COUNT(*) * 100.0), 1) AS rework_rate_pct,
    -- Settlement Rate (Audit Passed + Payment Notified)
    ROUND((COUNT(*) FILTER (WHERE cm.last_state IN ('Audit passed', 'Notification of payment'))::numeric / COUNT(*) * 100.0), 1) AS settlement_rate_pct,
    -- Averages
    ROUND(AVG(cm.touchpoints_count)::numeric, 1) AS avg_touchpoints,
    ROUND(AVG(cm.total_pages)::numeric, 1) AS avg_document_pages
FROM v_claim_master cm
JOIN dim_damage_type dt ON cm.damage_type = dt.damage_type_name
GROUP BY cm.damage_type, dt.complexity_tier
ORDER BY total_claims DESC;

COMMENT ON VIEW v_damage_scorecard IS 'Executive category-level performance scorecard across portfolio volume, duration, STP, and rework.';


-- ------------------------------------------------------------------------------
-- 5. VIEW: v_monthly_intake_trend (Monthly Portfolio Time Series)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly_intake_trend AS
WITH monthly_data AS (
    SELECT 
        intake_year_month,
        DATE_TRUNC('month', intake_timestamp) AS month_date,
        COUNT(*) AS intake_volume,
        COUNT(*) FILTER (WHERE is_stp_compliant = TRUE) AS stp_claims,
        COUNT(*) FILTER (WHERE has_rework_loop = TRUE) AS rework_claims,
        COUNT(*) FILTER (WHERE last_state = 'Audit passed') AS audit_passed_claims,
        ROUND(AVG(lifecycle_duration_days)::numeric, 2) AS mean_duration_days,
        ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY lifecycle_duration_days)::numeric, 2) AS median_duration_days,
        ROUND(AVG(total_pages)::numeric, 1) AS avg_pages
    FROM v_claim_master
    GROUP BY intake_year_month, DATE_TRUNC('month', intake_timestamp)
)
SELECT 
    intake_year_month,
    intake_volume,
    -- Month-over-Month Intake Change
    intake_volume - LAG(intake_volume, 1) OVER (ORDER BY month_date) AS mom_volume_change,
    ROUND(
        ((intake_volume - LAG(intake_volume, 1) OVER (ORDER BY month_date))::numeric 
         / NULLIF(LAG(intake_volume, 1) OVER (ORDER BY month_date), 0) * 100.0), 
        1
    ) AS mom_growth_pct,
    ROUND((stp_claims::numeric / intake_volume * 100.0), 1) AS stp_rate_pct,
    ROUND((rework_claims::numeric / intake_volume * 100.0), 1) AS rework_rate_pct,
    ROUND((audit_passed_claims::numeric / intake_volume * 100.0), 1) AS audit_pass_rate_pct,
    median_duration_days,
    mean_duration_days,
    avg_pages,
    ROUND(
        AVG(intake_volume) OVER (
            ORDER BY month_date 
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        )::numeric, 
        1
    ) AS rolling_3mo_avg_intake
FROM monthly_data
ORDER BY month_date;

COMMENT ON VIEW v_monthly_intake_trend IS 'Monthly operational trend mart tracking intake volume, STP rate, rework rate, and turnaround velocity.';
