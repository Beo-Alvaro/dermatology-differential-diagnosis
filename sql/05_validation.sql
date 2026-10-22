-- =============================================================================
-- 05_validation.sql
-- Purpose : 14 PASS/FAIL checks that the pipeline kept every row and every
--           value, plus a prevalence grid for tying out against Excel.
-- Run     : Via 00_run_all.sql, or on its own after 04_model.sql:
--             psql -U postgres -d derm -f sql/05_validation.sql
-- Notes   : Each check stores its expected and actual value as text; PASS
--           means they are identical. If any check fails, the DO block at the
--           end raises an error, so 00_run_all.sql exits with an error code
--           instead of letting a FAIL scroll past unnoticed.
-- =============================================================================

-- A TEMP table only exists for this psql session and vanishes afterwards.
DROP TABLE IF EXISTS pg_temp.validation_results;
CREATE TEMP TABLE validation_results (
    check_no    INT PRIMARY KEY,
    check_name  TEXT NOT NULL,
    expected    TEXT NOT NULL,
    actual      TEXT NOT NULL
);

-- ---- Row counts per layer ---------------------------------------------------

INSERT INTO validation_results
SELECT 1, 'Staging holds every CSV row', '366', COUNT(*)::TEXT
FROM staging.raw_dermatology;

INSERT INTO validation_results
SELECT 2, 'Clean table keeps every row', '366', COUNT(*)::TEXT
FROM analytics.dermatology_clean;

INSERT INTO validation_results
SELECT 3, 'patients has one row per patient', '366', COUNT(*)::TEXT
FROM analytics.patients;

INSERT INTO validation_results
SELECT 4, 'fact_findings = 366 x 32 rows', '11712', COUNT(*)::TEXT
FROM analytics.fact_findings;

-- ---- Dimensions -------------------------------------------------------------

INSERT INTO validation_results
SELECT 5, 'dim_disease has 6 diseases', '6', COUNT(*)::TEXT
FROM analytics.dim_disease;

INSERT INTO validation_results
SELECT 6, 'dim_feature split 10 / 22', 'Clinical 10, Histopathological 22',
       STRING_AGG(feature_group || ' ' || n, ', ' ORDER BY feature_group)
FROM (
    SELECT feature_group, COUNT(*) AS n
    FROM analytics.dim_feature
    GROUP BY feature_group
) AS g;

-- ---- Keys and structure -----------------------------------------------------

-- The PK makes ids unique, so min 1 + max 366 + 366 ids = no gaps.
INSERT INTO validation_results
SELECT 7, 'patient_id runs 1..366 in file order', '1..366 (366 ids)',
       MIN(patient_id) || '..' || MAX(patient_id) || ' (' || COUNT(*) || ' ids)'
FROM analytics.patients;

-- LEFT JOIN so a patient with zero fact rows would show up as a count of 0.
INSERT INTO validation_results
SELECT 8, 'Every patient has exactly 32 findings', '0 patients off', COUNT(*) || ' patients off'
FROM (
    SELECT p.patient_id, COUNT(f.feature_id) AS n_findings
    FROM analytics.patients AS p
    LEFT JOIN analytics.fact_findings AS f ON f.patient_id = p.patient_id
    GROUP BY p.patient_id
    HAVING COUNT(f.feature_id) <> 32
) AS off;

INSERT INTO validation_results
SELECT 9, 'Denormalized fact disease_id matches patients', '0 mismatches', COUNT(*) || ' mismatches'
FROM analytics.fact_findings AS f
JOIN analytics.patients AS p ON p.patient_id = f.patient_id
WHERE f.disease_id <> p.disease_id;

-- ---- Round trips back to the raw CSV ----------------------------------------

-- Staging columns use the same names as dim_feature.feature_key, so
-- to_jsonb(r) ->> feature_key looks up the raw text for any finding.
INSERT INTO validation_results
SELECT 10, 'Round trip: all 11,712 scores equal the raw CSV', '0 mismatches', COUNT(*) || ' mismatches'
FROM analytics.fact_findings AS f
JOIN analytics.dim_feature AS d ON d.feature_id = f.feature_id
JOIN staging.raw_dermatology AS r ON r.row_num = f.patient_id
WHERE f.score IS DISTINCT FROM TRIM(to_jsonb(r) ->> d.feature_key)::SMALLINT;

-- Re-applies the age rule from 03_clean.sql ('', '?' and '0' -> NULL).
-- IS DISTINCT FROM treats NULL = NULL as a match, unlike <>.
INSERT INTO validation_results
SELECT 11, 'Round trip: class, family history, age match raw CSV', '0 mismatches', COUNT(*) || ' mismatches'
FROM analytics.patients AS p
JOIN staging.raw_dermatology AS r ON r.row_num = p.patient_id
WHERE p.disease_id         IS DISTINCT FROM TRIM(r.class)::SMALLINT
   OR p.has_family_history IS DISTINCT FROM TRIM(r.family_history)::SMALLINT
   OR p.age IS DISTINCT FROM (
          CASE WHEN r.age IS NULL OR TRIM(r.age) IN ('', '?', '0') THEN NULL
               ELSE TRIM(r.age)::SMALLINT
          END);

-- ---- Known facts about this dataset -----------------------------------------

-- Published UCI class counts.
INSERT INTO validation_results
SELECT 12, 'Class counts match UCI (112/61/72/49/52/20)',
       '1:112, 2:61, 3:72, 4:49, 5:52, 6:20',
       STRING_AGG(disease_id || ':' || n, ', ' ORDER BY disease_id)
FROM (
    SELECT disease_id, COUNT(*) AS n
    FROM analytics.patients
    GROUP BY disease_id
) AS c;

-- 8 missing in source + 1 recorded as 0 (see 03_clean.sql).
INSERT INTO validation_results
SELECT 13, 'Ages: 9 unknown, known ages 7-75', '9 unknown, 7-75',
       COUNT(*) FILTER (WHERE age IS NULL) || ' unknown, ' || MIN(age) || '-' || MAX(age)
FROM analytics.patients;

INSERT INTO validation_results
SELECT 14, 'Unknown age band <=> missing age', '0 mismatches', COUNT(*) || ' mismatches'
FROM analytics.patients
WHERE (age IS NULL) <> (age_band = 'Unknown');

-- ---- Report -----------------------------------------------------------------

SELECT
    check_no,
    check_name,
    expected,
    actual,
    CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM validation_results
ORDER BY check_no;

-- DO runs a small anonymous PL/pgSQL block. RAISE EXCEPTION turns any FAIL
-- into an error, which stops 00_run_all.sql (ON_ERROR_STOP).
DO $$
DECLARE
    n_failed INT;
BEGIN
    SELECT COUNT(*) INTO n_failed
    FROM validation_results
    WHERE actual <> expected;

    IF n_failed > 0 THEN
        RAISE EXCEPTION '% of 14 validation checks FAILED. See the table above.', n_failed;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Excel tie-out: prevalence (% of patients with score >= 1) for every finding
-- in every disease. Build the same grid in Excel with COUNTIFS and compare.
-- AVG(...) FILTER (WHERE ...) computes one disease's average per column,
-- which pivots the six diseases into six columns in one pass.
-- -----------------------------------------------------------------------------
SELECT
    d.feature_id,
    d.feature_name,
    d.feature_group,
    ROUND(100 * AVG(f.is_present) FILTER (WHERE f.disease_id = 1), 1) AS psoriasis,
    ROUND(100 * AVG(f.is_present) FILTER (WHERE f.disease_id = 2), 1) AS seb_dermatitis,
    ROUND(100 * AVG(f.is_present) FILTER (WHERE f.disease_id = 3), 1) AS lichen_planus,
    ROUND(100 * AVG(f.is_present) FILTER (WHERE f.disease_id = 4), 1) AS pityriasis_rosea,
    ROUND(100 * AVG(f.is_present) FILTER (WHERE f.disease_id = 5), 1) AS chronic_dermatitis,
    ROUND(100 * AVG(f.is_present) FILTER (WHERE f.disease_id = 6), 1) AS pit_rubra_pilaris,
    ROUND(100 * AVG(f.is_present), 1)                                 AS all_patients
FROM analytics.fact_findings AS f
JOIN analytics.dim_feature AS d ON d.feature_id = f.feature_id
GROUP BY d.feature_id, d.feature_name, d.feature_group
ORDER BY d.feature_id;
