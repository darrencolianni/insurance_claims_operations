-- ==============================================================================
-- Insurance Claims Operations Analytics - Cohort & Temporal Trends
-- File: sql/03_cohort_and_temporal_trends.sql
-- Description: Longitudinal, time-series, and calendar analytics:
--              monthly cohorts, day-of-week intake distributions, hourly heatmaps,
--              aging buckets / SLA tracking, MoM/YoY growth, and rolling time windows.
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. MONTHLY INTAKE COHORTS & MOM GROWTH
-- ------------------------------------------------------------------------------

-- Query 1: Monthly Intake Volume, MoM Velocity Change, and Median Cycle Time
-- Tracks claims volume dynamics across the January 2014 - January 2020 timeline.
WITH monthly_cohorts AS (
    SELECT 
        DATE_TRUNC('month', first_event) AS cohort_month,
        COUNT(*) AS monthly_claims,
        ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
        ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days,
        ROUND(AVG(event_count)::numeric, 1) AS avg_events,
        ROUND(AVG(total_pages)::numeric, 1) AS avg_pages
    FROM claim_summary
    GROUP BY DATE_TRUNC('month', first_event)
)
SELECT 
    TO_CHAR(cohort_month, 'YYYY-MM') AS intake_month,
    monthly_claims,
    -- Month-over-Month volume change
    monthly_claims - LAG(monthly_claims, 1) OVER (ORDER BY cohort_month) AS mom_volume_change,
    ROUND(
        (
            (monthly_claims - LAG(monthly_claims, 1) OVER (ORDER BY cohort_month))::numeric 
            / NULLIF(LAG(monthly_claims, 1) OVER (ORDER BY cohort_month), 0) * 100.0
        ), 
        1
    ) AS mom_volume_growth_pct,
    median_duration_days,
    avg_duration_days,
    -- 3-Month Rolling Average of Monthly Intake
    ROUND(
        AVG(monthly_claims) OVER (
            ORDER BY cohort_month 
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        )::numeric, 
        1
    ) AS rolling_3mo_avg_intake
FROM monthly_cohorts
ORDER BY cohort_month
LIMIT 24;


-- ------------------------------------------------------------------------------
-- 2. ANNUAL PORTFOLIO SUMMARY & YOY DRIFT
-- ------------------------------------------------------------------------------

-- Query 2: Year-over-Year (YoY) Intake Volume and Operational Duration Trend
SELECT 
    EXTRACT(YEAR FROM first_event)::INT AS intake_year,
    COUNT(*) AS total_claims_filed,
    ROUND(AVG(duration_days)::numeric, 2) AS mean_duration_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS p90_duration_days,
    -- YoY Growth in Claim Intake
    ROUND(
        (
            (COUNT(*) - LAG(COUNT(*)) OVER (ORDER BY EXTRACT(YEAR FROM first_event)))::numeric 
            / NULLIF(LAG(COUNT(*)) OVER (ORDER BY EXTRACT(YEAR FROM first_event)), 0) * 100.0
        ), 
        1
    ) AS yoy_intake_growth_pct,
    -- Audit pass rate per year
    ROUND(
        (COUNT(CASE WHEN last_state = 'Audit passed' THEN 1 END)::numeric / COUNT(*) * 100.0), 
        1
    ) AS audit_pass_rate_pct
FROM claim_summary
GROUP BY EXTRACT(YEAR FROM first_event)
ORDER BY intake_year;


-- ------------------------------------------------------------------------------
-- 3. DAY-OF-WEEK OPERATIONAL INTAKE PATTERNS
-- ------------------------------------------------------------------------------

-- Query 3: Intake Volume and Processing Velocity by Day of Week
-- Informs adjuster staffing and initial triage prioritization.
SELECT 
    TO_CHAR(first_event, 'Dy') AS day_of_week_abbr,
    EXTRACT(ISODOW FROM first_event)::INT AS day_of_week_num, -- 1=Monday, 7=Sunday
    COUNT(*) AS claims_filed,
    ROUND((COUNT(*)::numeric / (SELECT COUNT(*) FROM claim_summary) * 100.0), 1) AS pct_of_portfolio,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days,
    ROUND(AVG(total_docs)::numeric, 2) AS avg_docs
FROM claim_summary
GROUP BY TO_CHAR(first_event, 'Dy'), EXTRACT(ISODOW FROM first_event)
ORDER BY day_of_week_num;


-- ------------------------------------------------------------------------------
-- 4. HOURLY INTAKE & SYSTEM ACTIVITY DISTRIBUTION
-- ------------------------------------------------------------------------------

-- Query 4: Hour-of-Day System Interaction Patterns
-- Compares when claims are initiated vs when documentation arrives vs when internal actions occur.
SELECT 
    EXTRACT(HOUR FROM event_timestamp)::INT AS hour_of_day,
    COUNT(*) AS total_system_events,
    COUNT(CASE WHEN state_name = 'Notification of claim' THEN 1 END) AS claim_notifications,
    COUNT(CASE WHEN state_name = 'Damage documents' THEN 1 END) AS document_submissions,
    COUNT(CASE WHEN state_name = 'Processing' THEN 1 END) AS adjuster_processings,
    COUNT(CASE WHEN state_name = 'Audit passed' THEN 1 END) AS audits_passed,
    ROUND(
        (COUNT(*)::numeric / (SELECT COUNT(*) FROM process_events) * 100.0), 
        2
    ) AS pct_of_total_events
FROM process_events
GROUP BY EXTRACT(HOUR FROM event_timestamp)
ORDER BY hour_of_day;


-- ------------------------------------------------------------------------------
-- 5. SLA AGING TIERS & CYCLE-TIME BUCKETING
-- ------------------------------------------------------------------------------

-- Query 5: Distribution of Claims Across Operational Aging Brackets
-- Highlights turnaround performance against industry service level standards.
WITH aging_prep AS (
    SELECT 
        instance_id,
        damage_type,
        duration_days,
        total_pages,
        CASE 
            WHEN duration_days < 1.0 THEN '1. Same-Day (< 24 hrs)'
            WHEN duration_days >= 1.0 AND duration_days < 3.0 THEN '2. Fast-Track (1-3 days)'
            WHEN duration_days >= 3.0 AND duration_days < 7.0 THEN '3. Standard SLA (3-7 days)'
            WHEN duration_days >= 7.0 AND duration_days < 14.0 THEN '4. Moderate Delay (7-14 days)'
            WHEN duration_days >= 14.0 AND duration_days < 30.0 THEN '5. Extended (14-30 days)'
            WHEN duration_days >= 30.0 AND duration_days < 90.0 THEN '6. Severely Delayed (30-90 days)'
            WHEN duration_days >= 90.0 AND duration_days < 365.0 THEN '7. Protracted (90-365 days)'
            ELSE '8. Extreme Inactivity (> 365 days)'
        END AS aging_bracket
    FROM claim_summary
)
SELECT 
    aging_bracket,
    COUNT(*) AS claim_count,
    ROUND((COUNT(*)::numeric / (SELECT COUNT(*) FROM claim_summary) * 100.0), 2) AS pct_of_claims,
    -- Cumulative percentage running total
    ROUND(
        (
            SUM(COUNT(*)) OVER (ORDER BY MIN(duration_days))::numeric 
            / (SELECT COUNT(*) FROM claim_summary) * 100.0
        ), 
        1
    ) AS cumulative_pct,
    ROUND(AVG(total_pages)::numeric, 1) AS avg_pages_logged,
    ROUND(MIN(duration_days)::numeric, 2) AS min_bracket_days,
    ROUND(MAX(duration_days)::numeric, 2) AS max_bracket_days
FROM aging_prep
GROUP BY aging_bracket
ORDER BY min_bracket_days;


-- ------------------------------------------------------------------------------
-- 6. DAMAGE TYPE AGING CROSS-TABULATION
-- ------------------------------------------------------------------------------

-- Query 6: Percentage of Claims Resolving in <= 7 Days vs > 30 Days by Damage Category
SELECT 
    damage_type,
    COUNT(*) AS total_claims,
    COUNT(CASE WHEN duration_days <= 7.0 THEN 1 END) AS claims_under_7d,
    ROUND(
        (COUNT(CASE WHEN duration_days <= 7.0 THEN 1 END)::numeric / COUNT(*) * 100.0), 
        1
    ) AS pct_under_7d,
    COUNT(CASE WHEN duration_days > 30.0 THEN 1 END) AS claims_over_30d,
    ROUND(
        (COUNT(CASE WHEN duration_days > 30.0 THEN 1 END)::numeric / COUNT(*) * 100.0), 
        1
    ) AS pct_over_30d,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days
FROM claim_summary
GROUP BY damage_type
ORDER BY total_claims DESC;
