-- =============================================================================
-- 00_run_all.sql
-- Purpose : Rebuild the whole pipeline from the raw CSV, in order: load,
--           profile, clean, model, run the 14 validation checks (every one
--           must say PASS), then create the analysis views.
-- Run     : From the repo root (01_staging.sql reads data/dermatology.csv
--           relative to the current folder):
--             createdb -U postgres derm                      # first time only
--             psql -U postgres -d derm -f sql/00_run_all.sql
-- Notes   : - ON_ERROR_STOP makes psql quit at the first error (including a
--             failed validation check) with a non-zero exit code.
--           - \ir includes a file relative to THIS file's folder (sql/), so
--             the includes work wherever psql is started from. Only \copy
--             depends on the current folder.
-- =============================================================================

\set ON_ERROR_STOP on
\pset pager off
-- Hide the NOTICE lines that DROP ... IF EXISTS prints on a first run.
SET client_min_messages = warning;

\echo '=== 01 staging: load raw CSV ==='
\ir 01_staging.sql

\echo '=== 02 profiling (read-only) ==='
\ir 02_profiling.sql

\echo '=== 03 clean: typed, constrained table ==='
\ir 03_clean.sql

\echo '=== 04 model: star schema ==='
\ir 04_model.sql

\echo '=== 05 validation: 14 checks ==='
\ir 05_validation.sql

-- Views come after validation, so they are only built on data that passed.
\echo '=== 06 analysis views ==='
\ir 06_analysis_views.sql

\echo '=== Done: all 14 checks passed, views created ==='
