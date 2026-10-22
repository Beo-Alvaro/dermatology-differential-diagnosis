-- =============================================================================
-- 06_analysis_views.sql
-- Purpose : One or more views per analysis question (see CLAUDE.md / README).
--           Power BI imports some of these directly; the rest are the SQL
--           answers quoted in the README.
-- Run     : Via 00_run_all.sql, or on its own after 04_model.sql:
--             psql -U postgres -d derm -f sql/06_analysis_views.sql
-- Metric definitions (used everywhere):
--   Prevalence         = % of patients in a group with score >= 1,
--                        i.e. AVG(is_present) x 100.
--   Signature strength = prevalence in a disease minus prevalence among all
--                        OTHER patients, in percentage points (pts).
-- Rounding: prevalence is rounded to 1 decimal ONCE, in the base view, and
--   every later number is built from those rounded values. The trade-off is
--   up to 0.1 pt of rounding error, in exchange for every number in SQL,
--   Power BI and the README matching what is displayed.
-- =============================================================================

DROP VIEW IF EXISTS analytics.vw_q5_atypical_by_disease     CASCADE;
DROP VIEW IF EXISTS analytics.vw_q5_patient_typicality      CASCADE;
DROP VIEW IF EXISTS analytics.vw_q4_red_flags               CASCADE;
DROP VIEW IF EXISTS analytics.vw_q4_finding_disease_mix     CASCADE;
DROP VIEW IF EXISTS analytics.vw_q3_pair_summary            CASCADE;
DROP VIEW IF EXISTS analytics.vw_q3_pair_feature_gaps       CASCADE;
DROP VIEW IF EXISTS analytics.vw_q2_non_discriminators      CASCADE;
DROP VIEW IF EXISTS analytics.vw_q2_signature_strength      CASCADE;
DROP VIEW IF EXISTS analytics.vw_q1_age_bands               CASCADE;
DROP VIEW IF EXISTS analytics.vw_q1_disease_profile         CASCADE;
DROP VIEW IF EXISTS analytics.vw_disease_feature_prevalence CASCADE;


-- =============================================================================
-- BASE: prevalence of every finding in every disease (6 x 32 = 192 rows),
-- plus prevalence among all other patients. Q2-Q5 build on this view.
-- =============================================================================
CREATE VIEW analytics.vw_disease_feature_prevalence AS
WITH counts AS (
    SELECT
        f.disease_id,
        f.feature_id,
        COUNT(*)           AS n_patients,
        SUM(f.is_present)  AS n_present
    FROM analytics.fact_findings AS f
    GROUP BY f.disease_id, f.feature_id
),
feature_totals AS (
    SELECT
        feature_id,
        SUM(n_patients)  AS n_patients_all,
        SUM(n_present)   AS n_present_all
    FROM counts
    GROUP BY feature_id
)
SELECT
    c.disease_id,
    dd.disease_name,
    dd.disease_abbrev,
    c.feature_id,
    df.feature_name,
    df.feature_group,
    c.n_patients,
    c.n_present,
    ROUND(100.0 * c.n_present / c.n_patients, 1)                        AS prevalence_pct,
    -- "Others" = everyone minus this disease: subtract this disease's counts
    -- from the feature totals.
    ROUND(100.0 * (t.n_present_all - c.n_present)
                / (t.n_patients_all - c.n_patients), 1)                 AS prevalence_others_pct
FROM counts AS c
JOIN feature_totals        AS t  ON t.feature_id  = c.feature_id
JOIN analytics.dim_disease AS dd ON dd.disease_id = c.disease_id
JOIN analytics.dim_feature AS df ON df.feature_id = c.feature_id;


-- =============================================================================
-- Q1. Who's in the data?
-- =============================================================================

-- One row per disease plus an "All patients" total row.
-- ROLLUP adds the total: it groups by disease AND by nothing (the grand
-- total), where the grouped columns come back as NULL.
-- PERCENTILE_CONT(0.5) is the median; like other aggregates it skips NULLs,
-- so unknown ages are excluded, and they are counted separately.
CREATE VIEW analytics.vw_q1_disease_profile AS
SELECT
    d.disease_id,
    COALESCE(d.disease_name, 'All patients')                                AS disease_name,
    COUNT(*)                                                                AS patients,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM analytics.patients), 1)  AS pct_of_patients,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.age))::NUMERIC, 1) AS median_age,
    MIN(p.age)                                                              AS min_age,
    MAX(p.age)                                                              AS max_age,
    COUNT(*) FILTER (WHERE p.age IS NULL)                                   AS unknown_age,
    ROUND(100.0 * AVG(p.has_family_history), 1)                             AS family_history_pct
FROM analytics.patients AS p
JOIN analytics.dim_disease AS d ON d.disease_id = p.disease_id
GROUP BY ROLLUP ((d.disease_id, d.disease_name))
ORDER BY d.disease_id NULLS LAST;

-- Age band mix within each disease (for a stacked bar).
CREATE VIEW analytics.vw_q1_age_bands AS
SELECT
    d.disease_id,
    d.disease_name,
    p.age_band,
    p.age_band_sort,
    COUNT(*)                                                                      AS patients,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY d.disease_id), 1)  AS pct_of_disease
FROM analytics.patients AS p
JOIN analytics.dim_disease AS d ON d.disease_id = p.disease_id
GROUP BY d.disease_id, d.disease_name, p.age_band, p.age_band_sort;


-- =============================================================================
-- Q2. What makes each disease distinctive, and which findings don't help?
-- =============================================================================

-- All 192 disease x finding rows with signature strength and a rank within
-- each disease. RANK() OVER (PARTITION BY disease ...) restarts at 1 for
-- every disease; ties share a rank. Top 5 = WHERE signature_rank <= 5.
CREATE VIEW analytics.vw_q2_signature_strength AS
SELECT
    p.disease_id,
    p.disease_name,
    p.feature_id,
    p.feature_name,
    p.feature_group,
    p.prevalence_pct,
    p.prevalence_others_pct,
    p.prevalence_pct - p.prevalence_others_pct           AS signature_strength_pts,
    RANK() OVER (
        PARTITION BY p.disease_id
        ORDER BY p.prevalence_pct - p.prevalence_others_pct DESC
    )                                                    AS signature_rank
FROM analytics.vw_disease_feature_prevalence AS p;

-- Spread = highest minus lowest prevalence across the six diseases. A finding
-- that is about equally common in every disease (small spread) can't help
-- tell them apart. spread_rank 1 = least useful finding.
CREATE VIEW analytics.vw_q2_non_discriminators AS
SELECT
    p.feature_id,
    p.feature_name,
    p.feature_group,
    ROUND(100.0 * SUM(p.n_present) / SUM(p.n_patients), 1)  AS overall_prevalence_pct,
    MIN(p.prevalence_pct)                                    AS min_prevalence_pct,
    MAX(p.prevalence_pct)                                    AS max_prevalence_pct,
    MAX(p.prevalence_pct) - MIN(p.prevalence_pct)            AS spread_pts,
    RANK() OVER (ORDER BY MAX(p.prevalence_pct) - MIN(p.prevalence_pct)) AS spread_rank
FROM analytics.vw_disease_feature_prevalence AS p
GROUP BY p.feature_id, p.feature_name, p.feature_group;


-- =============================================================================
-- Q3 (headline). Which diseases can be told apart clinically, and which
-- need a biopsy?
-- =============================================================================

-- Every disease pair x every finding: 15 pairs x 32 = 480 rows.
-- The self-join matches the prevalence view to itself on the same finding;
-- a.disease_id < b.disease_id keeps each pair once (PSO vs LP, never LP vs
-- PSO) and never pairs a disease with itself.
-- Power BI imports this view and recomputes "sharp" against a what-if
-- parameter; is_sharp here uses the default 50-point cutoff.
CREATE VIEW analytics.vw_q3_pair_feature_gaps AS
WITH params AS (
    SELECT 50 AS sharp_gap_pts      -- the one place to change the SQL cutoff
)
SELECT
    a.disease_id * 10 + b.disease_id                        AS pair_id,   -- 12, 13, ... 56
    a.disease_abbrev || ' vs ' || b.disease_abbrev          AS pair_label,
    a.disease_id                                            AS disease_a_id,
    a.disease_name                                          AS disease_a,
    b.disease_id                                            AS disease_b_id,
    b.disease_name                                          AS disease_b,
    a.feature_id,
    a.feature_name,
    a.feature_group,
    a.prevalence_pct                                        AS prevalence_a_pct,
    b.prevalence_pct                                        AS prevalence_b_pct,
    ABS(a.prevalence_pct - b.prevalence_pct)                AS gap_pts,
    CASE WHEN ABS(a.prevalence_pct - b.prevalence_pct) >= prm.sharp_gap_pts
         THEN 1 ELSE 0 END                                  AS is_sharp
FROM analytics.vw_disease_feature_prevalence AS a
JOIN analytics.vw_disease_feature_prevalence AS b
    ON  b.feature_id = a.feature_id
    AND a.disease_id < b.disease_id
CROSS JOIN params AS prm;

-- One row per pair (15 rows). Shares are normalized by group size: there are
-- 10 clinical and 22 histopathological findings, so raw counts would favour
-- histopathology. AVG(is_sharp) over a group = sharp count / group size.
CREATE VIEW analytics.vw_q3_pair_summary AS
WITH pair_shares AS (
    SELECT
        g.pair_id,
        g.pair_label,
        g.disease_a,
        g.disease_b,
        SUM(g.is_sharp) FILTER (WHERE g.feature_group = 'Clinical')                   AS sharp_clinical,
        ROUND(100.0 * AVG(g.is_sharp) FILTER (WHERE g.feature_group = 'Clinical'), 1) AS sharp_clinical_pct,
        SUM(g.is_sharp) FILTER (WHERE g.feature_group = 'Histopathological')          AS sharp_histo,
        ROUND(100.0 * AVG(g.is_sharp) FILTER (WHERE g.feature_group = 'Histopathological'), 1) AS sharp_histo_pct,
        MAX(g.gap_pts) FILTER (WHERE g.feature_group = 'Clinical')                    AS best_clinical_gap_pts,
        MAX(g.gap_pts) FILTER (WHERE g.feature_group = 'Histopathological')           AS best_histo_gap_pts
    FROM analytics.vw_q3_pair_feature_gaps AS g
    GROUP BY g.pair_id, g.pair_label, g.disease_a, g.disease_b
)
SELECT
    ps.*,
    ps.sharp_histo_pct - ps.sharp_clinical_pct  AS biopsy_lift_pts,
    -- Labels: a pair is clinically separable if at least one clinical finding
    -- has a sharp gap. Otherwise it needs the biopsy, if histopathology has a
    -- sharp gap, or stays hard even with one.
    CASE
        WHEN ps.sharp_clinical >= 1 THEN 'Clinically separable'
        WHEN ps.sharp_histo    >= 1 THEN 'Biopsy-dependent'
        ELSE 'Hard even with biopsy'
    END                                         AS verdict
FROM pair_shares AS ps;


-- =============================================================================
-- Q4. Which findings point almost entirely to one disease?
-- Among patients who have a finding at score >= k, what share belong to each
-- disease? A "red flag" is a finding where one disease is >= 80% of them.
-- k = 1 (finding present at all) vs k = 2 (finding moderate or strong).
-- =============================================================================

-- Long format for Power BI's 100% stacked bar: finding x k x disease.
-- generate_series(1, 2) makes a two-row table {1, 2}; joining on
-- score >= k counts each patient once for every threshold they reach.
CREATE VIEW analytics.vw_q4_finding_disease_mix AS
WITH thresholds AS (
    SELECT generate_series(1, 2) AS min_score
),
counts AS (
    SELECT
        t.min_score,
        f.feature_id,
        f.disease_id,
        COUNT(*) AS n_patients
    FROM analytics.fact_findings AS f
    JOIN thresholds AS t ON f.score >= t.min_score
    GROUP BY t.min_score, f.feature_id, f.disease_id
)
SELECT
    c.min_score,
    c.feature_id,
    df.feature_name,
    df.feature_group,
    c.disease_id,
    dd.disease_name,
    c.n_patients,
    SUM(c.n_patients) OVER (PARTITION BY c.min_score, c.feature_id)  AS n_with_finding,
    ROUND(100.0 * c.n_patients
          / SUM(c.n_patients) OVER (PARTITION BY c.min_score, c.feature_id), 1) AS share_pct
FROM counts AS c
JOIN analytics.dim_feature AS df ON df.feature_id = c.feature_id
JOIN analytics.dim_disease AS dd ON dd.disease_id = c.disease_id;

-- One row per finding x k: the disease with the biggest share.
-- ROW_NUMBER() picks exactly one top disease per group (ties broken by
-- disease_id). min_support stops a finding seen in only a handful of
-- patients from counting as a red flag: 100% of 3 patients isn't evidence.
CREATE VIEW analytics.vw_q4_red_flags AS
WITH params AS (
    SELECT 80 AS red_flag_share_pct,
           10 AS min_support
),
ranked AS (
    SELECT
        m.*,
        ROW_NUMBER() OVER (
            PARTITION BY m.min_score, m.feature_id
            ORDER BY m.n_patients DESC, m.disease_id
        ) AS rn
    FROM analytics.vw_q4_finding_disease_mix AS m
)
SELECT
    r.min_score,
    r.feature_id,
    r.feature_name,
    r.feature_group,
    r.n_with_finding,
    r.disease_name   AS top_disease,
    r.n_patients     AS n_top_disease,
    r.share_pct      AS top_share_pct,
    CASE WHEN r.share_pct >= prm.red_flag_share_pct
          AND r.n_with_finding >= prm.min_support
         THEN 1 ELSE 0 END AS is_red_flag
FROM ranked AS r
CROSS JOIN params AS prm
WHERE r.rn = 1;


-- =============================================================================
-- Q5. How many patients are atypical?
-- Atypical = missing at least one of their own disease's top 3 signature
-- findings (score >= 1), i.e. fewer than 3 of the 3.
-- Cutoff tuned on the real counts: "fewer than 2 of 3" flagged only 2 of 366
-- patients (signatures are strong), which says little. Requiring all 3 flags
-- 55 patients (15%) and shows WHICH diseases present atypically. The 0/1/2/3
-- distribution in vw_q5_atypical_by_disease shows both readings.
-- =============================================================================

-- One row per patient. ROW_NUMBER (not RANK) so every disease gets exactly
-- 3 signature findings even if two are tied; ties go to the lower feature_id.
CREATE VIEW analytics.vw_q5_patient_typicality AS
WITH params AS (
    SELECT 3 AS min_top3_present    -- atypical if fewer than this many of the top 3
),
top3 AS (
    SELECT disease_id, feature_id
    FROM (
        SELECT
            s.disease_id,
            s.feature_id,
            ROW_NUMBER() OVER (
                PARTITION BY s.disease_id
                ORDER BY s.signature_strength_pts DESC, s.feature_id
            ) AS rn
        FROM analytics.vw_q2_signature_strength AS s
    ) AS ranked
    WHERE rn <= 3
)
SELECT
    p.patient_id,
    p.disease_id,
    d.disease_name,
    SUM(f.is_present)                                     AS top3_present,  -- 0 to 3
    CASE WHEN SUM(f.is_present) < prm.min_top3_present
         THEN 1 ELSE 0 END                                AS is_atypical
FROM analytics.patients AS p
JOIN analytics.dim_disease AS d ON d.disease_id = p.disease_id
JOIN top3 AS t ON t.disease_id = p.disease_id
JOIN analytics.fact_findings AS f
    ON  f.patient_id = p.patient_id
    AND f.feature_id = t.feature_id
CROSS JOIN params AS prm
GROUP BY p.patient_id, p.disease_id, d.disease_name, prm.min_top3_present;

-- Count and % atypical per disease, plus how many patients have 0/1/2/3 of
-- the top 3 (use this distribution to tune the cutoff).
CREATE VIEW analytics.vw_q5_atypical_by_disease AS
SELECT
    t.disease_id,
    t.disease_name,
    COUNT(*)                                        AS patients,
    SUM(t.is_atypical)                              AS atypical,
    ROUND(100.0 * AVG(t.is_atypical), 1)            AS atypical_pct,
    COUNT(*) FILTER (WHERE t.top3_present = 0)      AS with_0_of_3,
    COUNT(*) FILTER (WHERE t.top3_present = 1)      AS with_1_of_3,
    COUNT(*) FILTER (WHERE t.top3_present = 2)      AS with_2_of_3,
    COUNT(*) FILTER (WHERE t.top3_present = 3)      AS with_3_of_3
FROM analytics.vw_q5_patient_typicality AS t
GROUP BY t.disease_id, t.disease_name;


-- Quick look at the headline answer.
SELECT * FROM analytics.vw_q3_pair_summary ORDER BY biopsy_lift_pts DESC;
