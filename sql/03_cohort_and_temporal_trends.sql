
-- ==============================================================================
-- Insurance Claims Operations Analytics - Cohort & Temporal Trends
-- File: sql/03_cohort_and_temporal_trends.sql
-- Description: Monthly cohorts, annual trends, intake patterns, hourly activity,
--              cycle-time aging, and damage-type comparisons.
-- Outlier exclusion: Claims with duration_days > 730 are excluded.
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- Shared population: exclude claims exceeding 24 months.

-- ------------------------------------------------------------------------------
-- 1. MONTHLY INTAKE COHORTS & MOM GROWTH
-- ------------------------------------------------------------------------------

WITH eligible_claims AS (
    SELECT *
    FROM claim_summary
    WHERE duration_days <= 730
),
month_calendar AS (
    SELECT generate_series(
        DATE_TRUNC('month', MIN(first_event)),
        DATE_TRUNC('month', MAX(first_event)),
        INTERVAL '1 month'
    ) AS cohort_month
    FROM eligible_claims
),
monthly_cohorts AS (
    SELECT
        DATE_TRUNC('month', first_event) AS cohort_month,
        COUNT(*) AS monthly_claims,
        ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
        ROUND(
            PERCENTILE_CONT(0.50)
            WITHIN GROUP (ORDER BY duration_days)::numeric,
            2
        ) AS median_duration_days
    FROM eligible_claims
    GROUP BY DATE_TRUNC('month', first_event)
),
monthly_series AS (
    SELECT
        mc.cohort_month,
        COALESCE(m.monthly_claims, 0) AS monthly_claims,
        m.avg_duration_days,
        m.median_duration_days
    FROM month_calendar mc
    LEFT JOIN monthly_cohorts m
        ON mc.cohort_month = m.cohort_month
),
monthly_metrics AS (
    SELECT
        cohort_month,
        monthly_claims,
        monthly_claims
            - LAG(monthly_claims) OVER (ORDER BY cohort_month)
            AS mom_volume_change,
        ROUND(
            (
                (
                    monthly_claims
                    - LAG(monthly_claims) OVER (ORDER BY cohort_month)
                )::numeric
                / NULLIF(
                    LAG(monthly_claims) OVER (ORDER BY cohort_month),
                    0
                )
            ) * 100.0,
            1
        ) AS mom_volume_growth_pct,
        median_duration_days,
        avg_duration_days,
        ROUND(
            AVG(monthly_claims) OVER (
                ORDER BY cohort_month
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            )::numeric,
            1
        ) AS rolling_3mo_avg_intake
    FROM monthly_series
)
SELECT
    TO_CHAR(cohort_month, 'YYYY-MM') AS intake_month,
    monthly_claims,
    mom_volume_change,
    mom_volume_growth_pct,
    median_duration_days,
    avg_duration_days,
    rolling_3mo_avg_intake
FROM monthly_metrics
ORDER BY cohort_month;


-- ------------------------------------------------------------------------------
-- 2. ANNUAL PORTFOLIO SUMMARY & YOY DRIFT
-- ------------------------------------------------------------------------------

WITH annual_metrics AS (
    SELECT
        EXTRACT(YEAR FROM first_event)::INT AS intake_year,
        COUNT(*) AS total_claims_filed,
        ROUND(AVG(duration_days)::numeric, 2) AS mean_duration_days,
        ROUND(
            PERCENTILE_CONT(0.50)
            WITHIN GROUP (ORDER BY duration_days)::numeric,
            2
        ) AS median_duration_days,
        ROUND(
            PERCENTILE_CONT(0.90)
            WITHIN GROUP (ORDER BY duration_days)::numeric,
            2
        ) AS p90_duration_days,
        ROUND(
            COUNT(*) FILTER (
                WHERE last_state = 'Audit passed'
            )::numeric / COUNT(*) * 100.0,
            1
        ) AS pct_claims_ending_audit_passed
    FROM claim_summary
    WHERE duration_days <= 730
    GROUP BY EXTRACT(YEAR FROM first_event)
)
SELECT
    intake_year,
    total_claims_filed,
    mean_duration_days,
    median_duration_days,
    p90_duration_days,
    ROUND(
        (
            (
                total_claims_filed
                - LAG(total_claims_filed) OVER (ORDER BY intake_year)
            )::numeric
            / NULLIF(
                LAG(total_claims_filed) OVER (ORDER BY intake_year),
                0
            )
        ) * 100.0,
        1
    ) AS yoy_intake_growth_pct,
    pct_claims_ending_audit_passed
FROM annual_metrics
ORDER BY intake_year;


-- ------------------------------------------------------------------------------
-- 3. DAY-OF-WEEK OPERATIONAL INTAKE PATTERNS
-- ------------------------------------------------------------------------------

SELECT
    TO_CHAR(first_event, 'Dy') AS day_of_week_abbr,
    EXTRACT(ISODOW FROM first_event)::INT AS day_of_week_num,
    COUNT(*) AS claims_filed,
    ROUND(
        COUNT(*)::numeric
        / (
            SELECT COUNT(*)
            FROM claim_summary
            WHERE duration_days <= 730
        ) * 100.0,
        1
    ) AS pct_of_portfolio,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS median_duration_days,
    ROUND(AVG(total_docs)::numeric, 2) AS avg_docs
FROM claim_summary
WHERE duration_days <= 730
GROUP BY
    TO_CHAR(first_event, 'Dy'),
    EXTRACT(ISODOW FROM first_event)
ORDER BY day_of_week_num;


-- ------------------------------------------------------------------------------
-- 4. HOURLY SYSTEM ACTIVITY DISTRIBUTION
-- ------------------------------------------------------------------------------

-- Only events belonging to claims within the 24-month cutoff are included.
-- event_timestamp is stored in UTC.

SELECT
    EXTRACT(HOUR FROM pe.event_timestamp)::INT AS hour_of_day,
    COUNT(*) AS total_system_events,
    COUNT(*) FILTER (
        WHERE pe.state_name = 'Notification of claim'
    ) AS claim_notifications,
    COUNT(*) FILTER (
        WHERE pe.state_name = 'Damage documents'
    ) AS document_submissions,
    COUNT(*) FILTER (
        WHERE pe.state_name = 'Processing'
    ) AS adjuster_processings,
    COUNT(*) FILTER (
        WHERE pe.state_name = 'Audit passed'
    ) AS audits_passed,
    ROUND(
        COUNT(*)::numeric
        / (
            SELECT COUNT(*)
            FROM process_events pe2
            JOIN claim_summary cs2
                ON pe2.instance_id = cs2.instance_id
            WHERE cs2.duration_days <= 730
        ) * 100.0,
        2
    ) AS pct_of_total_events
FROM process_events pe
JOIN claim_summary cs
    ON pe.instance_id = cs.instance_id
WHERE cs.duration_days <= 730
GROUP BY EXTRACT(HOUR FROM pe.event_timestamp)
ORDER BY hour_of_day;


-- ------------------------------------------------------------------------------
-- 5. CYCLE-TIME AGING BUCKETS
-- ------------------------------------------------------------------------------

WITH aging_prep AS (
    SELECT
        instance_id,
        duration_days,
        total_pages,
        CASE
            WHEN duration_days < 1.0
                THEN '1. Same-Day (< 24 hrs)'
            WHEN duration_days < 3.0
                THEN '2. Fast-Track (1-3 days)'
            WHEN duration_days < 7.0
                THEN '3. Standard (3-7 days)'
            WHEN duration_days < 14.0
                THEN '4. Moderate Delay (7-14 days)'
            WHEN duration_days < 30.0
                THEN '5. Extended (14-30 days)'
            WHEN duration_days < 90.0
                THEN '6. Severely Delayed (30-90 days)'
            WHEN duration_days < 365.0
                THEN '7. Protracted (90-365 days)'
            ELSE '8. Extreme Inactivity (365-730 days)'
        END AS aging_bracket
    FROM claim_summary
    WHERE duration_days <= 730
),
bracket_metrics AS (
    SELECT
        aging_bracket,
        COUNT(*) AS claim_count,
        ROUND(AVG(total_pages)::numeric, 1) AS avg_pages_logged,
        MIN(duration_days) AS min_bracket_days,
        MAX(duration_days) AS max_bracket_days
    FROM aging_prep
    GROUP BY aging_bracket
)
SELECT
    aging_bracket,
    claim_count,
    ROUND(
        claim_count::numeric
        / (SELECT COUNT(*) FROM aging_prep) * 100.0,
        2
    ) AS pct_of_claims,
    ROUND(
        SUM(claim_count) OVER (
            ORDER BY min_bracket_days
        )::numeric
        / (SELECT COUNT(*) FROM aging_prep) * 100.0,
        1
    ) AS cumulative_pct,
    avg_pages_logged,
    ROUND(min_bracket_days::numeric, 2) AS min_bracket_days,
    ROUND(max_bracket_days::numeric, 2) AS max_bracket_days
FROM bracket_metrics
ORDER BY min_bracket_days;


-- ------------------------------------------------------------------------------
-- 6. DAMAGE TYPE CYCLE-TIME COMPARISON
-- ------------------------------------------------------------------------------

SELECT
    damage_type,
    COUNT(*) AS total_claims,
    COUNT(*) FILTER (
        WHERE duration_days <= 7.0
    ) AS claims_within_7d,
    ROUND(
        COUNT(*) FILTER (
            WHERE duration_days <= 7.0
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS pct_within_7d,
    COUNT(*) FILTER (
        WHERE duration_days > 30.0
    ) AS claims_over_30d,
    ROUND(
        COUNT(*) FILTER (
            WHERE duration_days > 30.0
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS pct_over_30d,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS median_duration_days
FROM claim_summary
WHERE duration_days <= 730
GROUP BY damage_type
ORDER BY total_claims DESC;
