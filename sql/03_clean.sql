-- =============================================================================
-- 03_clean.sql
-- Purpose : Build analytics.dermatology_clean: one row per patient with real
--           data types and constraints. Bad data FAILS LOUDLY here (the
--           insert errors out) instead of slipping through into the model.
-- Run     : Via 00_run_all.sql, or on its own after 01_staging.sql:
--             psql -U postgres -d derm -f sql/03_clean.sql
--           Rerun 04-06 afterwards (00_run_all does this), because dropping
--           the domain below also drops the columns that use it.
-- Decisions (evidence from 02_profiling.sql):
--   1. Missing ages arrive as '?' (UCI original) or blank (some copies).
--      Both become NULL, with age_note = 'Missing in source'.
--   2. One psoriasis patient (row 120 in UCI order) has age 0. Every other age
--      is 7 or more, and a newborn with chronic psoriasis is implausible, so 0
--      is treated as a missing-value code: age = NULL,
--      age_note = 'Recorded as 0; treated as missing'.
--   3. eosinophils_in_the_infiltrate only ranges 0-2 in the data. That is real
--      (nobody scored 3), not an error, so it keeps the same 0-3 domain.
-- =============================================================================

DROP TABLE  IF EXISTS analytics.dermatology_clean CASCADE;
DROP DOMAIN IF EXISTS analytics.finding_score CASCADE;

-- A DOMAIN is a reusable data type with rules attached. Every finding column
-- (here and in fact_findings) uses it, so the 0-3 rule is written once.
CREATE DOMAIN analytics.finding_score AS SMALLINT
    NOT NULL
    CHECK (VALUE BETWEEN 0 AND 3);

CREATE TABLE analytics.dermatology_clean (
    patient_id                                INT PRIMARY KEY,   -- = staging row_num (file order)

    -- Clinical findings (UCI 1-10), then family history (UCI 11)
    erythema                                  analytics.finding_score,
    scaling                                   analytics.finding_score,
    definite_borders                          analytics.finding_score,
    itching                                   analytics.finding_score,
    koebner_phenomenon                        analytics.finding_score,
    polygonal_papules                         analytics.finding_score,
    follicular_papules                        analytics.finding_score,
    oral_mucosal_involvement                  analytics.finding_score,
    knee_and_elbow_involvement                analytics.finding_score,
    scalp_involvement                         analytics.finding_score,
    family_history                            SMALLINT NOT NULL CHECK (family_history IN (0, 1)),

    -- Histopathological findings (UCI 12-33)
    melanin_incontinence                      analytics.finding_score,
    eosinophils_in_the_infiltrate             analytics.finding_score,
    pnl_infiltrate                            analytics.finding_score,
    fibrosis_of_the_papillary_dermis          analytics.finding_score,
    exocytosis                                analytics.finding_score,
    acanthosis                                analytics.finding_score,
    hyperkeratosis                            analytics.finding_score,
    parakeratosis                             analytics.finding_score,
    clubbing_of_the_rete_ridges               analytics.finding_score,
    elongation_of_the_rete_ridges             analytics.finding_score,
    thinning_of_the_suprapapillary_epidermis  analytics.finding_score,
    spongiform_pustule                        analytics.finding_score,
    munro_microabscess                        analytics.finding_score,
    focal_hypergranulosis                     analytics.finding_score,
    disappearance_of_the_granular_layer       analytics.finding_score,
    vacuolisation_and_damage_of_basal_layer   analytics.finding_score,
    spongiosis                                analytics.finding_score,
    saw_tooth_appearance_of_retes             analytics.finding_score,
    follicular_horn_plug                      analytics.finding_score,
    perifollicular_parakeratosis              analytics.finding_score,
    inflammatory_mononuclear_infiltrate       analytics.finding_score,
    band_like_infiltrate                      analytics.finding_score,

    age                                       SMALLINT CHECK (age BETWEEN 1 AND 120),  -- NULL = unknown
    age_note                                  TEXT,
    disease_id                                SMALLINT NOT NULL CHECK (disease_id BETWEEN 1 AND 6)
);

-- Each ::SMALLINT cast fails loudly on anything that isn't a whole number
-- (e.g. a stray '?' in a finding column), and the domain / CHECK constraints
-- reject numbers outside their allowed range.
INSERT INTO analytics.dermatology_clean
SELECT
    r.row_num,

    TRIM(r.erythema)::SMALLINT,
    TRIM(r.scaling)::SMALLINT,
    TRIM(r.definite_borders)::SMALLINT,
    TRIM(r.itching)::SMALLINT,
    TRIM(r.koebner_phenomenon)::SMALLINT,
    TRIM(r.polygonal_papules)::SMALLINT,
    TRIM(r.follicular_papules)::SMALLINT,
    TRIM(r.oral_mucosal_involvement)::SMALLINT,
    TRIM(r.knee_and_elbow_involvement)::SMALLINT,
    TRIM(r.scalp_involvement)::SMALLINT,
    TRIM(r.family_history)::SMALLINT,

    TRIM(r.melanin_incontinence)::SMALLINT,
    TRIM(r.eosinophils_in_the_infiltrate)::SMALLINT,
    TRIM(r.pnl_infiltrate)::SMALLINT,
    TRIM(r.fibrosis_of_the_papillary_dermis)::SMALLINT,
    TRIM(r.exocytosis)::SMALLINT,
    TRIM(r.acanthosis)::SMALLINT,
    TRIM(r.hyperkeratosis)::SMALLINT,
    TRIM(r.parakeratosis)::SMALLINT,
    TRIM(r.clubbing_of_the_rete_ridges)::SMALLINT,
    TRIM(r.elongation_of_the_rete_ridges)::SMALLINT,
    TRIM(r.thinning_of_the_suprapapillary_epidermis)::SMALLINT,
    TRIM(r.spongiform_pustule)::SMALLINT,
    TRIM(r.munro_microabscess)::SMALLINT,
    TRIM(r.focal_hypergranulosis)::SMALLINT,
    TRIM(r.disappearance_of_the_granular_layer)::SMALLINT,
    TRIM(r.vacuolisation_and_damage_of_basal_layer)::SMALLINT,
    TRIM(r.spongiosis)::SMALLINT,
    TRIM(r.saw_tooth_appearance_of_retes)::SMALLINT,
    TRIM(r.follicular_horn_plug)::SMALLINT,
    TRIM(r.perifollicular_parakeratosis)::SMALLINT,
    TRIM(r.inflammatory_mononuclear_infiltrate)::SMALLINT,
    TRIM(r.band_like_infiltrate)::SMALLINT,

    -- age: decisions 1 and 2 above. CASE checks the missing codes first, so
    -- the cast only ever sees real values.
    CASE
        WHEN r.age IS NULL OR TRIM(r.age) IN ('', '?') THEN NULL
        WHEN TRIM(r.age) = '0'                          THEN NULL
        ELSE TRIM(r.age)::SMALLINT
    END,
    CASE
        WHEN r.age IS NULL OR TRIM(r.age) IN ('', '?') THEN 'Missing in source'
        WHEN TRIM(r.age) = '0'                          THEN 'Recorded as 0; treated as missing'
    END,

    TRIM(r.class)::SMALLINT
FROM staging.raw_dermatology AS r
ORDER BY r.row_num;

SELECT
    COUNT(*)                             AS patients,
    COUNT(*) FILTER (WHERE age IS NULL)  AS unknown_age,
    MIN(age)                             AS min_known_age,
    MAX(age)                             AS max_known_age
FROM analytics.dermatology_clean;
