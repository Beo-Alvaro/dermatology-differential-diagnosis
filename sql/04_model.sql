-- =============================================================================
-- 04_model.sql
-- Purpose : Build the star schema in `analytics` that Power BI imports:
--             dim_disease    6 rows
--             dim_feature   32 rows (10 Clinical, 22 Histopathological)
--             patients     366 rows (one per patient)
--             fact_findings 11,712 rows (366 patients x 32 findings)
-- Run     : Via 00_run_all.sql, or on its own after 03_clean.sql:
--             psql -U postgres -d derm -f sql/04_model.sql
-- Notes   : fact_findings.disease_id is a denormalized copy of
--           patients.disease_id, kept only to make SQL shorter. In Power BI
--           the path is dim_disease -> patients -> fact_findings; hide
--           fact_findings[disease_id] there so it is never used by mistake.
-- =============================================================================

DROP TABLE IF EXISTS analytics.fact_findings CASCADE;
DROP TABLE IF EXISTS analytics.patients      CASCADE;
DROP TABLE IF EXISTS analytics.dim_feature   CASCADE;
DROP TABLE IF EXISTS analytics.dim_disease   CASCADE;

-- -----------------------------------------------------------------------------
-- dim_disease: the six diagnoses (the UCI class codes).
-- -----------------------------------------------------------------------------
CREATE TABLE analytics.dim_disease (
    disease_id      SMALLINT PRIMARY KEY,
    disease_name    TEXT NOT NULL UNIQUE,
    disease_abbrev  TEXT NOT NULL UNIQUE    -- short label for pair charts, e.g. 'PSO vs LP'
);

INSERT INTO analytics.dim_disease (disease_id, disease_name, disease_abbrev) VALUES
    (1, 'Psoriasis',                'PSO'),
    (2, 'Seborrheic dermatitis',    'SD'),
    (3, 'Lichen planus',            'LP'),
    (4, 'Pityriasis rosea',         'PR'),
    (5, 'Chronic dermatitis',       'CD'),
    (6, 'Pityriasis rubra pilaris', 'PRP');

-- -----------------------------------------------------------------------------
-- dim_feature: the 32 scored findings. family_history (UCI 11) is 0/1, not a
-- 0-3 finding, so it lives on `patients` instead and 11 is skipped here.
--   feature_id    = UCI attribute number (keeps the original order)
--   feature_key   = column name in dermatology_clean (used for the unpivot)
--   feature_name  = display name for reports
-- -----------------------------------------------------------------------------
CREATE TABLE analytics.dim_feature (
    feature_id     SMALLINT PRIMARY KEY,
    feature_key    TEXT NOT NULL UNIQUE,
    feature_name   TEXT NOT NULL UNIQUE,
    feature_group  TEXT NOT NULL CHECK (feature_group IN ('Clinical', 'Histopathological'))
);

INSERT INTO analytics.dim_feature (feature_id, feature_key, feature_name, feature_group) VALUES
    ( 1, 'erythema',                                 'Erythema',                                 'Clinical'),
    ( 2, 'scaling',                                  'Scaling',                                  'Clinical'),
    ( 3, 'definite_borders',                         'Definite borders',                         'Clinical'),
    ( 4, 'itching',                                  'Itching',                                  'Clinical'),
    ( 5, 'koebner_phenomenon',                       'Koebner phenomenon',                       'Clinical'),
    ( 6, 'polygonal_papules',                        'Polygonal papules',                        'Clinical'),
    ( 7, 'follicular_papules',                       'Follicular papules',                       'Clinical'),
    ( 8, 'oral_mucosal_involvement',                 'Oral mucosal involvement',                 'Clinical'),
    ( 9, 'knee_and_elbow_involvement',               'Knee and elbow involvement',               'Clinical'),
    (10, 'scalp_involvement',                        'Scalp involvement',                        'Clinical'),
    (12, 'melanin_incontinence',                     'Melanin incontinence',                     'Histopathological'),
    (13, 'eosinophils_in_the_infiltrate',            'Eosinophils in the infiltrate',            'Histopathological'),
    (14, 'pnl_infiltrate',                           'PNL infiltrate',                           'Histopathological'),
    (15, 'fibrosis_of_the_papillary_dermis',         'Fibrosis of the papillary dermis',         'Histopathological'),
    (16, 'exocytosis',                               'Exocytosis',                               'Histopathological'),
    (17, 'acanthosis',                               'Acanthosis',                               'Histopathological'),
    (18, 'hyperkeratosis',                           'Hyperkeratosis',                           'Histopathological'),
    (19, 'parakeratosis',                            'Parakeratosis',                            'Histopathological'),
    (20, 'clubbing_of_the_rete_ridges',              'Clubbing of the rete ridges',              'Histopathological'),
    (21, 'elongation_of_the_rete_ridges',            'Elongation of the rete ridges',            'Histopathological'),
    (22, 'thinning_of_the_suprapapillary_epidermis', 'Thinning of the suprapapillary epidermis', 'Histopathological'),
    (23, 'spongiform_pustule',                       'Spongiform pustule',                       'Histopathological'),
    (24, 'munro_microabscess',                       'Munro microabscess',                       'Histopathological'),
    (25, 'focal_hypergranulosis',                    'Focal hypergranulosis',                    'Histopathological'),
    (26, 'disappearance_of_the_granular_layer',      'Disappearance of the granular layer',      'Histopathological'),
    (27, 'vacuolisation_and_damage_of_basal_layer',  'Vacuolisation and damage of basal layer',  'Histopathological'),
    (28, 'spongiosis',                               'Spongiosis',                               'Histopathological'),
    (29, 'saw_tooth_appearance_of_retes',            'Saw-tooth appearance of retes',            'Histopathological'),
    (30, 'follicular_horn_plug',                     'Follicular horn plug',                     'Histopathological'),
    (31, 'perifollicular_parakeratosis',             'Perifollicular parakeratosis',             'Histopathological'),
    (32, 'inflammatory_mononuclear_infiltrate',      'Inflammatory mononuclear infiltrate',      'Histopathological'),
    (33, 'band_like_infiltrate',                     'Band-like infiltrate',                     'Histopathological');

-- -----------------------------------------------------------------------------
-- patients: one row per patient, with age bands for the Overview page.
-- -----------------------------------------------------------------------------
CREATE TABLE analytics.patients (
    patient_id          INT PRIMARY KEY,
    disease_id          SMALLINT NOT NULL REFERENCES analytics.dim_disease (disease_id),
    age                 SMALLINT,                -- NULL = unknown
    age_band            TEXT NOT NULL,
    age_band_sort       SMALLINT NOT NULL,       -- Power BI "Sort by column" for age_band
    age_note            TEXT,
    -- 0/1 rather than BOOLEAN so AVG() (SQL) and AVERAGE() (DAX) give the rate.
    has_family_history  SMALLINT NOT NULL CHECK (has_family_history IN (0, 1))
);

-- The bands are defined once, as a small inline table (VALUES), and matched
-- by range. A patient with no age matches no band and falls to 'Unknown'.
WITH age_bands (age_band, age_band_sort, min_age, max_age) AS (
    VALUES
        ('Under 18', 1,  0,  17),
        ('18-29',    2, 18,  29),
        ('30-44',    3, 30,  44),
        ('45-59',    4, 45,  59),
        ('60+',      5, 60, 120)
)
INSERT INTO analytics.patients
    (patient_id, disease_id, age, age_band, age_band_sort, age_note, has_family_history)
SELECT
    c.patient_id,
    c.disease_id,
    c.age,
    COALESCE(b.age_band, 'Unknown'),
    COALESCE(b.age_band_sort, 6),
    c.age_note,
    c.family_history
FROM analytics.dermatology_clean AS c
LEFT JOIN age_bands AS b
    ON c.age BETWEEN b.min_age AND b.max_age;

-- -----------------------------------------------------------------------------
-- fact_findings: one row per patient per finding (the "long" format that
-- Power BI and GROUP BY queries want).
--   is_present is a GENERATED column: Postgres computes it from score on every
--   insert/update, so it can never disagree with score. Prevalence is then
--   simply AVG(is_present).
-- -----------------------------------------------------------------------------
CREATE TABLE analytics.fact_findings (
    patient_id  INT      NOT NULL REFERENCES analytics.patients (patient_id),
    feature_id  SMALLINT NOT NULL REFERENCES analytics.dim_feature (feature_id),
    disease_id  SMALLINT NOT NULL REFERENCES analytics.dim_disease (disease_id),  -- denormalized
    score       analytics.finding_score,
    is_present  SMALLINT GENERATED ALWAYS AS (CASE WHEN score >= 1 THEN 1 ELSE 0 END) STORED,
    PRIMARY KEY (patient_id, feature_id)
);

-- Unpivot wide -> long, the same jsonb trick as 02_profiling.sql:
-- to_jsonb(c) turns a patient row into key/value pairs, and the INNER JOIN to
-- dim_feature on feature_key keeps only the 32 findings (patient_id, age,
-- family_history, etc. have no match, so they drop out).
INSERT INTO analytics.fact_findings (patient_id, feature_id, disease_id, score)
SELECT
    c.patient_id,
    f.feature_id,
    c.disease_id,
    kv.value::SMALLINT
FROM analytics.dermatology_clean AS c
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(c)) AS kv (key, value)
JOIN analytics.dim_feature AS f
    ON f.feature_key = kv.key;

-- Row counts per table, as a quick visual check.
SELECT 'dim_disease'   AS table_name, COUNT(*) AS row_count FROM analytics.dim_disease
UNION ALL
SELECT 'dim_feature',   COUNT(*) FROM analytics.dim_feature
UNION ALL
SELECT 'patients',      COUNT(*) FROM analytics.patients
UNION ALL
SELECT 'fact_findings', COUNT(*) FROM analytics.fact_findings;
