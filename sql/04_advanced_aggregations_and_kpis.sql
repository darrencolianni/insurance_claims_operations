-- ==============================================================================
-- Insurance Claims Operations Analytics - Advanced Aggregations & Operational KPIs
-- File: sql/04_advanced_aggregations_and_kpis.sql
-- Description: Advanced aggregation constructs: GROUPING SETS, ROLLUP, CUBE,
--              FILTER (WHERE ...) single-pass KPI scorecards, statistical
--              percentiles, IQR, correlation coefficients (CORR), and Z-score outlier detection.
-- Target DB: PostgreSQL 14+
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. GROUPING SETS, ROLLUP & CUBE: Multi-Dimensional Portfolio Rollups
-- ------------------------------------------------------------------------------

-- Query 1A: Hierarchical ROLLUP (Damage Category -> Outcome State -> Grand Total)
-- Generates subtotals for each damage category and an executive grand total row.
SELECT 
    CASE 
        WHEN GROUPING(cs.damage_type) = 1 THEN '== PORTFOLIO GRAND TOTAL =='
        ELSE cs.damage_type 
    END AS damage_category,
    CASE 
        WHEN GROUPING(cs.last_state) = 1 THEN '-- All Outcomes Subtotal --'
        ELSE cs.last_state 
    END AS final_state,
    COUNT(*) AS total_claims,
    ROUND(AVG(cs.duration_days)::numeric, 2) AS mean_duration_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cs.duration_days)::numeric, 2) AS median_duration_days,
    ROUND(AVG(cs.total_pages)::numeric, 1) AS mean_pages,
    ROUND(AVG(cs.event_count)::numeric, 1) AS mean_events
FROM claim_summary cs
GROUP BY ROLLUP(cs.damage_type, cs.last_state)
ORDER BY GROUPING(cs.damage_type) DESC, cs.damage_type, GROUPING(cs.last_state) DESC, total_claims DESC;


-- Query 1B: Multi-Dimensional CUBE (Damage Category x Document Volume Bracket)
-- Computes every permutation of damage type and document page volume.
SELECT 
    COALESCE(damage_type, '** ALL DAMAGE TYPES **') AS damage_type,
    COALESCE(page_bracket, '** ALL BRACKETS **') AS page_bracket,
    COUNT(*) AS claims_count,
    ROUND(AVG(duration_days)::numeric, 2) AS avg_duration_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days
FROM claim_summary
WHERE damage_type IN ('Glass damage', 'Parking damage')
GROUP BY CUBE(damage_type, page_bracket)
ORDER BY damage_type, page_bracket;


-- ------------------------------------------------------------------------------
-- 2. FILTER (WHERE ...): Single-Pass Executive Operational Scorecard
-- ------------------------------------------------------------------------------

-- Query 2: Single-Scan Portfolio Scorecard using Filtered Aggregations
-- Evaluates key operational KPIs across damage categories without multiple table scans.
SELECT 
    damage_type,
    COUNT(*) AS total_claims,
    -- Audit Settlement Rate
    COUNT(*) FILTER (WHERE last_state = 'Audit passed') AS audit_passed_claims,
    ROUND(
        (COUNT(*) FILTER (WHERE last_state = 'Audit passed')::numeric / COUNT(*) * 100.0), 
        1
    ) AS audit_pass_rate_pct,
    -- Payment Notification Rate
    COUNT(*) FILTER (WHERE last_state = 'Notification of payment') AS payment_notified_claims,
    ROUND(
        (COUNT(*) FILTER (WHERE last_state = 'Notification of payment')::numeric / COUNT(*) * 100.0), 
        1
    ) AS payment_rate_pct,
    -- Rejection Rate
    COUNT(*) FILTER (WHERE last_state = 'Rejection') AS rejected_claims,
    ROUND(
        (COUNT(*) FILTER (WHERE last_state = 'Rejection')::numeric / COUNT(*) * 100.0), 
        1
    ) AS rejection_rate_pct,
    -- Friction / Inquiry Rate
    COUNT(*) FILTER (WHERE event_count >= 8) AS high_touchpoint_claims,
    ROUND(
        (COUNT(*) FILTER (WHERE event_count >= 8)::numeric / COUNT(*) * 100.0), 
        1
    ) AS high_touch_pct,
    -- Fast Track Resolution Rate (<= 3 days)
    ROUND(
        (COUNT(*) FILTER (WHERE duration_days <= 3.0)::numeric / COUNT(*) * 100.0), 
        1
    ) AS resolved_within_3d_pct,
    -- Document Free Claims
    COUNT(*) FILTER (WHERE total_docs = 0) AS zero_doc_claims
FROM claim_summary
GROUP BY damage_type
ORDER BY total_claims DESC;


-- ------------------------------------------------------------------------------
-- 3. STATISTICAL PERCENTILES, SKEWNESS METRICS & IQR
-- ------------------------------------------------------------------------------

-- Query 3: Non-Parametric Percentiles & Interquartile Range (IQR) by Damage Type
-- Robust dispersion metrics resilient to extreme duration outliers.
SELECT 
    damage_type,
    COUNT(*) AS n_claims,
    -- Central Tendency: Median (P50) vs Mean
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_p50,
    ROUND(AVG(duration_days)::numeric, 2) AS mean_duration,
    -- Quartiles
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS q1_duration_p25,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS q3_duration_p75,
    -- Interquartile Range (IQR = Q3 - Q1)
    ROUND(
        (PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration_days) 
         - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY duration_days))::numeric, 
        2
    ) AS iqr_duration,
    -- Tail Percentiles
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS p90_duration,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS p95_duration,
    -- Parametric Dispersion
    ROUND(STDDEV_SAMP(duration_days)::numeric, 2) AS std_dev_duration,
    -- Skewness Indicator: (Mean - Median) / StdDev
    ROUND(
        ((AVG(duration_days) - PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)) 
         / NULLIF(STDDEV_SAMP(duration_days), 0))::numeric, 
        2
    ) AS non_parametric_skew_index
FROM claim_summary
GROUP BY damage_type
ORDER BY n_claims DESC;


-- ------------------------------------------------------------------------------
-- 4. CORRELATION ANALYSIS (CORR): Document Volume vs Lifecycle Duration
-- ------------------------------------------------------------------------------

-- Query 4: Pearson Correlation Coefficients
-- Evaluates the empirical association between document pages, event count, and duration.
SELECT 
    damage_type,
    COUNT(*) AS sample_size,
    -- Correlation between Total Pages and Duration
    ROUND(CORR(total_pages, duration_days)::numeric, 4) AS corr_pages_vs_duration,
    -- Correlation between Event Count (Touchpoints) and Duration
    ROUND(CORR(event_count, duration_days)::numeric, 4) AS corr_events_vs_duration,
    -- Correlation between Total Pages and Event Count
    ROUND(CORR(total_pages, event_count)::numeric, 4) AS corr_pages_vs_events
FROM claim_summary
GROUP BY damage_type
HAVING COUNT(*) > 20
ORDER BY sample_size DESC;


-- ------------------------------------------------------------------------------
-- 5. STATISTICAL OUTLIER DETECTION VIA STANDARDIZED Z-SCORE
-- ------------------------------------------------------------------------------

-- Query 5: Identifying Extreme Statistical Outliers (Z-Score > 3.0)
-- Claims whose lifecycle duration deviates by more than 3 standard deviations from their category mean.
WITH category_stats AS (
    SELECT 
        damage_type,
        AVG(duration_days) AS mean_dur,
        STDDEV_SAMP(duration_days) AS std_dur
    FROM claim_summary
    GROUP BY damage_type
),
claim_zscores AS (
    SELECT 
        cs.instance_id,
        cs.damage_type,
        cs.first_event::DATE AS intake_date,
        cs.last_state,
        cs.event_count,
        cs.total_docs,
        cs.total_pages,
        ROUND(cs.duration_days::numeric, 2) AS duration_days,
        ROUND(stat.mean_dur::numeric, 2) AS category_mean_days,
        ROUND(stat.std_dur::numeric, 2) AS category_std_days,
        ROUND(
            ((cs.duration_days - stat.mean_dur) / NULLIF(stat.std_dur, 0))::numeric, 
            2
        ) AS duration_z_score
    FROM claim_summary cs
    JOIN category_stats stat ON cs.damage_type = stat.damage_type
)
SELECT 
    instance_id,
    damage_type,
    intake_date,
    last_state,
    event_count,
    total_docs,
    total_pages,
    duration_days,
    category_mean_days,
    duration_z_score
FROM claim_zscores
WHERE duration_z_score >= 3.0
ORDER BY duration_z_score DESC
LIMIT 15;


-- ------------------------------------------------------------------------------
-- 6. DOCUMENT COMPLEXITY MATRIX
-- ------------------------------------------------------------------------------

-- Query 6: Operational Cycle Times across Document Page Brackets
SELECT 
    page_bracket,
    COUNT(*) AS total_claims,
    ROUND((COUNT(*)::numeric / (SELECT COUNT(*) FROM claim_summary) * 100.0), 1) AS pct_of_claims,
    ROUND(AVG(total_docs)::numeric, 1) AS avg_docs,
    ROUND(AVG(total_pages)::numeric, 1) AS avg_pages,
    ROUND(AVG(duration_days)::numeric, 2) AS mean_duration_days,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_days)::numeric, 2) AS median_duration_days,
    ROUND(
        (COUNT(CASE WHEN last_state = 'Audit passed' THEN 1 END)::numeric / COUNT(*) * 100.0), 
        1
    ) AS audit_pass_rate_pct
FROM claim_summary
GROUP BY page_bracket
ORDER BY median_duration_days ASC;
