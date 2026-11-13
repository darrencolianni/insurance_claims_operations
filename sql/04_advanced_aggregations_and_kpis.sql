-- ==============================================================================
-- Insurance Claims Operations Analytics - Advanced Aggregations & Operational KPIs
-- File: sql/04_advanced_aggregations_and_kpis.sql
-- Description: GROUPING SETS, ROLLUP, CUBE, filtered KPI aggregations,
--              percentiles, IQR, correlations, and Z-score outlier detection.
-- Target DB: PostgreSQL 14+
-- Operational analyses exclude claims exceeding their damage-type IQR upper fence.
-- Queries 3 and 5 retain all claims for outlier detection.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 0. DAMAGE-TYPE-SPECIFIC IQR FENCES
-- ------------------------------------------------------------------------------

-- Persistent view used to consistently identify duration outliers
-- across this file and downstream operational analyses.

CREATE OR REPLACE VIEW v_damage_type_duration_fences AS
WITH category_stats AS (
    SELECT
        damage_type,
        COUNT(*) AS total_claims,
        PERCENTILE_CONT(0.25)
            WITHIN GROUP (ORDER BY duration_days) AS q1,
        PERCENTILE_CONT(0.75)
            WITHIN GROUP (ORDER BY duration_days) AS q3
    FROM claim_summary
    GROUP BY damage_type
)
SELECT
    damage_type,
    total_claims,
    q1,
    q3,
    q3 - q1 AS iqr,
    q3 + 1.5 * (q3 - q1) AS upper_fence
FROM category_stats;

COMMENT ON VIEW v_damage_type_duration_fences IS
'Damage-type-specific Q1, Q3, IQR, and upper outlier fence calculated using the 1.5 × IQR rule. Used by operational analyses to exclude duration outliers.';


-- ------------------------------------------------------------------------------
-- 1. GROUPING SETS, ROLLUP & CUBE
-- ------------------------------------------------------------------------------

-- Query 1A: Hierarchical ROLLUP (Damage Category -> Outcome State -> Grand Total).

SELECT
    CASE
        WHEN GROUPING(cs.damage_type) = 1
            THEN '== PORTFOLIO GRAND TOTAL =='
        ELSE cs.damage_type
    END AS damage_category,
    CASE
        WHEN GROUPING(cs.last_state) = 1
            THEN '-- All Outcomes Subtotal --'
        ELSE cs.last_state
    END AS final_state,
    COUNT(*) AS total_claims,
    ROUND(AVG(cs.duration_days)::numeric, 2) AS mean_duration_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY cs.duration_days)::numeric,
        2
    ) AS median_duration_days,
    ROUND(AVG(cs.total_pages)::numeric, 1) AS mean_pages,
    ROUND(AVG(cs.event_count)::numeric, 1) AS mean_events
FROM claim_summary cs
JOIN v_damage_type_duration_fences f
    ON cs.damage_type = f.damage_type
WHERE cs.duration_days <= f.upper_fence
GROUP BY ROLLUP(cs.damage_type, cs.last_state)
ORDER BY
    GROUPING(cs.damage_type) DESC,
    cs.damage_type,
    GROUPING(cs.last_state) DESC,
    total_claims DESC;


-- Query 1B: Multi-Dimensional CUBE (Damage Category x Document Volume Bracket).

SELECT
    CASE
        WHEN GROUPING(cs.damage_type) = 1
            THEN '** ALL DAMAGE TYPES **'
        ELSE cs.damage_type
    END AS damage_type,
    CASE
        WHEN GROUPING(cs.page_bracket) = 1
            THEN '** ALL BRACKETS **'
        ELSE cs.page_bracket
    END AS page_bracket,
    COUNT(*) AS claims_count,
    ROUND(AVG(cs.duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY cs.duration_days)::numeric,
        2
    ) AS median_duration_days
FROM claim_summary cs
JOIN v_damage_type_duration_fences f
    ON cs.damage_type = f.damage_type
WHERE cs.damage_type IN ('Glass damage', 'Parking damage')
  AND cs.duration_days <= f.upper_fence
GROUP BY CUBE(cs.damage_type, cs.page_bracket)
ORDER BY
    GROUPING(cs.damage_type) DESC,
    cs.damage_type,
    GROUPING(cs.page_bracket) DESC,
    cs.page_bracket;


-- ------------------------------------------------------------------------------
-- 2. FILTERED OPERATIONAL KPI SCORECARD
-- ------------------------------------------------------------------------------

-- Query 2: Operational Outcomes and Claim Complexity by Damage Category.
-- Outcome percentages represent the share of claims ending in each state.
-- High touchpoint claims are defined as claims with at least 8 events.

SELECT
    cs.damage_type,
    COUNT(*) AS total_claims,

    COUNT(*) FILTER (
        WHERE cs.last_state = 'Audit passed'
    ) AS audit_passed_claims,

    ROUND(
        COUNT(*) FILTER (
            WHERE cs.last_state = 'Audit passed'
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS pct_claims_ending_audit_passed,

    COUNT(*) FILTER (
        WHERE cs.last_state = 'Notification of payment'
    ) AS payment_notified_claims,

    ROUND(
        COUNT(*) FILTER (
            WHERE cs.last_state = 'Notification of payment'
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS pct_claims_ending_payment_notified,

    COUNT(*) FILTER (
        WHERE cs.last_state = 'Rejection'
    ) AS rejected_claims,

    ROUND(
        COUNT(*) FILTER (
            WHERE cs.last_state = 'Rejection'
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS pct_claims_ending_rejected,

    COUNT(*) FILTER (
        WHERE cs.event_count >= 8
    ) AS high_touchpoint_claims,

    ROUND(
        COUNT(*) FILTER (
            WHERE cs.event_count >= 8
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS high_touchpoint_pct,

    ROUND(
        COUNT(*) FILTER (
            WHERE cs.duration_days <= 3.0
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS resolved_within_3d_pct,

    COUNT(*) FILTER (
        WHERE cs.total_docs = 0
    ) AS zero_doc_claims

FROM claim_summary cs
JOIN v_damage_type_duration_fences f
    ON cs.damage_type = f.damage_type
WHERE cs.duration_days <= f.upper_fence
GROUP BY cs.damage_type
ORDER BY total_claims DESC;


-- ------------------------------------------------------------------------------
-- 3. IQR-BASED DURATION OUTLIER DETECTION BY DAMAGE TYPE
-- ------------------------------------------------------------------------------

-- Query 3: Summarize duration outliers by damage type.
-- Uses the complete dataset; no outliers are excluded.

WITH outlier_summary AS (
    SELECT
        f.damage_type,
        COUNT(cs.instance_id) AS outlier_claims,
        AVG(cs.duration_days) AS avg_outlier_duration,
        MAX(cs.duration_days) AS max_outlier_duration
    FROM v_damage_type_duration_fences f
    LEFT JOIN claim_summary cs
        ON cs.damage_type = f.damage_type
        AND cs.duration_days > f.upper_fence
    GROUP BY f.damage_type
)
SELECT
    f.damage_type,
    f.total_claims,
    ROUND(f.q1::numeric, 2) AS q1_duration,
    ROUND(f.q3::numeric, 2) AS q3_duration,
    ROUND(f.iqr::numeric, 2) AS iqr_duration,
    ROUND(f.upper_fence::numeric, 2) AS upper_fence,
    os.outlier_claims,
    ROUND(
        os.outlier_claims::numeric / f.total_claims * 100,
        2
    ) AS pct_outlier_claims,
    ROUND(os.avg_outlier_duration::numeric, 2) AS avg_outlier_duration,
    ROUND(os.max_outlier_duration::numeric, 2) AS max_outlier_duration
FROM v_damage_type_duration_fences f
JOIN outlier_summary os
    ON f.damage_type = os.damage_type
ORDER BY os.outlier_claims DESC;


-- ------------------------------------------------------------------------------
-- 4. CORRELATION ANALYSIS
-- ------------------------------------------------------------------------------

-- Query 4: Pearson Correlations Between Documentation, Touchpoints, and Duration.
-- Correlations describe association, not causation.
-- Excludes duration outliers using damage-type-specific IQR fences.

SELECT
    cs.damage_type,
    COUNT(*) AS sample_size,

    ROUND(
        CORR(cs.total_pages, cs.duration_days)::numeric,
        4
    ) AS corr_pages_vs_duration,

    ROUND(
        CORR(cs.event_count, cs.duration_days)::numeric,
        4
    ) AS corr_events_vs_duration,

    ROUND(
        CORR(cs.total_pages, cs.event_count)::numeric,
        4
    ) AS corr_pages_vs_events

FROM claim_summary cs
JOIN v_damage_type_duration_fences f
    ON cs.damage_type = f.damage_type
WHERE cs.duration_days <= f.upper_fence
GROUP BY cs.damage_type
HAVING COUNT(*) > 20
ORDER BY sample_size DESC;


-- ------------------------------------------------------------------------------
-- 5. DOCUMENT COMPLEXITY MATRIX
-- ------------------------------------------------------------------------------

-- Query 5: Operational Cycle Times Across Document Page Brackets.
-- Excludes duration outliers using damage-type-specific IQR fences.

WITH operational_claims AS (
    SELECT cs.*
    FROM claim_summary cs
    JOIN v_damage_type_duration_fences f
        ON cs.damage_type = f.damage_type
    WHERE cs.duration_days <= f.upper_fence
)
SELECT
    page_bracket,
    COUNT(*) AS total_claims,

    ROUND(
        COUNT(*)::numeric
        / (SELECT COUNT(*) FROM operational_claims)
        * 100.0,
        1
    ) AS pct_of_claims,

    ROUND(AVG(total_docs)::numeric, 1) AS avg_docs,
    ROUND(AVG(total_pages)::numeric, 1) AS avg_pages,
    ROUND(AVG(duration_days)::numeric, 2) AS mean_duration_days,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (ORDER BY duration_days)::numeric,
        2
    ) AS median_duration_days,

    ROUND(
        COUNT(*) FILTER (
            WHERE last_state = 'Audit passed'
        )::numeric / COUNT(*) * 100.0,
        1
    ) AS pct_claims_ending_audit_passed

FROM operational_claims
GROUP BY page_bracket
ORDER BY median_duration_days ASC;