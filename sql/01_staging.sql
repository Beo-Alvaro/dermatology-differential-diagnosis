-- =============================================================================
-- 01_staging.sql
-- Purpose : Create the staging and analytics schemas, then load the raw CSV
--           into staging.raw_dermatology with every column stored as TEXT.
-- Run     : From the repo root, because \copy reads data/dermatology.csv
--           relative to the current folder. Normally run via 00_run_all.sql:
--             psql -U postgres -d derm -f sql/00_run_all.sql
-- Notes   : - Everything is TEXT so the load never fails on a bad value.
--             Typing and validation happen in 03_clean.sql, where each
--             decision can be commented.
--           - Columns are mapped by POSITION. The CSV header row is skipped,
--             so its typos ("microabcess", "monoluclear inflitrate") and
--             hyphens don't matter. Staging uses corrected snake_case names.
--           - row_num records file order and becomes patient_id later.
-- =============================================================================

-- Full rebuild: dropping both schemas removes every object this pipeline made,
-- so each run starts from a clean slate. Trade-off: anything else saved in
-- these two schemas is lost too, so keep ad hoc work in another schema.
DROP SCHEMA IF EXISTS analytics CASCADE;
DROP SCHEMA IF EXISTS staging CASCADE;

CREATE SCHEMA staging;
CREATE SCHEMA analytics;

CREATE TABLE staging.raw_dermatology (
    -- File order. GENERATED ALWAYS means Postgres assigns 1, 2, 3, ... as
    -- \copy inserts the rows, so row_num = line number of the data row.
    row_num                                   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Clinical findings (UCI attributes 1-11)
    erythema                                  TEXT,
    scaling                                   TEXT,
    definite_borders                          TEXT,
    itching                                   TEXT,
    koebner_phenomenon                        TEXT,
    polygonal_papules                         TEXT,
    follicular_papules                        TEXT,
    oral_mucosal_involvement                  TEXT,
    knee_and_elbow_involvement                TEXT,
    scalp_involvement                         TEXT,
    family_history                            TEXT,

    -- Histopathological findings (UCI attributes 12-33)
    melanin_incontinence                      TEXT,
    eosinophils_in_the_infiltrate             TEXT,
    pnl_infiltrate                            TEXT,
    fibrosis_of_the_papillary_dermis          TEXT,
    exocytosis                                TEXT,
    acanthosis                                TEXT,
    hyperkeratosis                            TEXT,
    parakeratosis                             TEXT,
    clubbing_of_the_rete_ridges               TEXT,
    elongation_of_the_rete_ridges             TEXT,
    thinning_of_the_suprapapillary_epidermis  TEXT,
    spongiform_pustule                        TEXT,
    munro_microabscess                        TEXT,   -- source: "munro_microabcess"
    focal_hypergranulosis                     TEXT,
    disappearance_of_the_granular_layer       TEXT,
    vacuolisation_and_damage_of_basal_layer   TEXT,
    spongiosis                                TEXT,
    saw_tooth_appearance_of_retes             TEXT,   -- source: "saw-tooth_..."
    follicular_horn_plug                      TEXT,
    perifollicular_parakeratosis              TEXT,
    inflammatory_mononuclear_infiltrate       TEXT,   -- source: "monoluclear inflitrate"
    band_like_infiltrate                      TEXT,   -- source: "band-like_..."

    age                                       TEXT,   -- UCI attribute 34
    class                                     TEXT    -- disease 1-6
);

-- \copy is a psql command (not SQL): psql reads the file on this machine and
-- streams it to the server, so no server file permissions are needed. It must
-- stay on ONE line. HEADER true skips the first line without checking names.
\copy staging.raw_dermatology (erythema, scaling, definite_borders, itching, koebner_phenomenon, polygonal_papules, follicular_papules, oral_mucosal_involvement, knee_and_elbow_involvement, scalp_involvement, family_history, melanin_incontinence, eosinophils_in_the_infiltrate, pnl_infiltrate, fibrosis_of_the_papillary_dermis, exocytosis, acanthosis, hyperkeratosis, parakeratosis, clubbing_of_the_rete_ridges, elongation_of_the_rete_ridges, thinning_of_the_suprapapillary_epidermis, spongiform_pustule, munro_microabscess, focal_hypergranulosis, disappearance_of_the_granular_layer, vacuolisation_and_damage_of_basal_layer, spongiosis, saw_tooth_appearance_of_retes, follicular_horn_plug, perifollicular_parakeratosis, inflammatory_mononuclear_infiltrate, band_like_infiltrate, age, class) FROM 'data/dermatology.csv' WITH (FORMAT csv, HEADER true)

SELECT COUNT(*) AS rows_loaded FROM staging.raw_dermatology;
