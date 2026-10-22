-- =============================================================================
-- 02_profiling.sql
-- Purpose : Read-only profile of staging.raw_dermatology, run BEFORE any
--           cleaning so every cleaning decision in 03_clean.sql is based on
--           evidence: blanks, '?' codes, ranges, distinct values, missing
--           ages by class, suspicious ages and duplicate rows.
-- Run     : Via 00_run_all.sql, or on its own after 01_staging.sql:
--             psql -U postgres -d derm -f sql/02_profiling.sql
-- Notes   : Changes nothing. Safe to run any time.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Column profile: one row per source column, in file order.
--    to_jsonb(r) turns each row into {"erythema": "2", "scaling": "1", ...};
--    jsonb_each_text then splits that object into one (key, value) row per
--    column. This "unpivot" lets one GROUP BY profile all 35 columns instead
--    of writing 35 near-identical queries.
-- -----------------------------------------------------------------------------
WITH long_values AS (
    SELECT
        r.row_num,
        kv.key          AS column_name,
        TRIM(kv.value)  AS value       -- NULL when the CSV field was empty
    FROM staging.raw_dermatology AS r
    CROSS JOIN LATERAL jsonb_each_text(to_jsonb(r) - 'row_num') AS kv (key, value)
)
SELECT
    col.ordinal_position - 1                                        AS col_no,
    lv.column_name,
    COUNT(*) FILTER (WHERE lv.value IS NULL OR lv.value = '')       AS n_blank,
    COUNT(*) FILTER (WHERE lv.value = '?')                          AS n_question_mark,
    COUNT(*) FILTER (WHERE lv.value !~ '^[0-9]+$'
                       AND lv.value NOT IN ('', '?'))               AS n_other_non_integer,
    MIN(lv.value::INT) FILTER (WHERE lv.value ~ '^[0-9]+$')         AS min_value,
    MAX(lv.value::INT) FILTER (WHERE lv.value ~ '^[0-9]+$')         AS max_value,
    COUNT(DISTINCT lv.value)                                        AS n_distinct,
    -- Only list the values for short lists (the findings), not for age.
    CASE WHEN COUNT(DISTINCT lv.value) <= 10
         THEN STRING_AGG(DISTINCT lv.value, ', ' ORDER BY lv.value)
    END                                                             AS distinct_values
FROM long_values AS lv
-- information_schema.columns gives each column's position, so the output is
-- in file order (jsonb stores keys in its own order, not the table's).
JOIN information_schema.columns AS col
    ON  col.table_schema = 'staging'
    AND col.table_name   = 'raw_dermatology'
    AND col.column_name  = lv.column_name
GROUP BY col.ordinal_position, lv.column_name
ORDER BY col.ordinal_position;

-- -----------------------------------------------------------------------------
-- 2. Class distribution and missing ages by class.
--    Shows whether missing ages cluster in one disease (which would bias any
--    age comparison) or are spread out.
-- -----------------------------------------------------------------------------
SELECT
    r.class,
    COUNT(*)                                                         AS patients,
    COUNT(*) FILTER (WHERE r.age IS NULL OR TRIM(r.age) IN ('', '?')) AS missing_age
FROM staging.raw_dermatology AS r
GROUP BY r.class
ORDER BY r.class;

-- -----------------------------------------------------------------------------
-- 3. Suspicious ages: present but not a plausible whole number of years.
--    CASE is used instead of AND/OR because Postgres may evaluate AND/OR
--    conditions in any order; CASE guarantees the ::INT cast only runs on
--    values already known to be digits.
-- -----------------------------------------------------------------------------
SELECT
    r.row_num,
    r.age,
    r.class
FROM staging.raw_dermatology AS r
WHERE CASE
          WHEN r.age IS NULL OR TRIM(r.age) IN ('', '?') THEN FALSE  -- missing: counted in query 2
          WHEN TRIM(r.age) !~ '^[0-9]+$'                 THEN TRUE   -- not a whole number
          ELSE TRIM(r.age)::INT NOT BETWEEN 1 AND 120
      END
ORDER BY r.row_num;

-- -----------------------------------------------------------------------------
-- 4. Exact duplicate rows (every column equal, ignoring row_num).
--    Grouping by the whole row as one jsonb value avoids listing 35 columns.
-- -----------------------------------------------------------------------------
WITH row_groups AS (
    SELECT
        to_jsonb(r) - 'row_num'   AS row_values,
        COUNT(*)                  AS copies,
        ARRAY_AGG(r.row_num)      AS row_nums
    FROM staging.raw_dermatology AS r
    GROUP BY to_jsonb(r) - 'row_num'
)
SELECT
    COUNT(*) FILTER (WHERE copies > 1)                         AS duplicate_groups,
    COALESCE(SUM(copies - 1) FILTER (WHERE copies > 1), 0)     AS extra_rows
FROM row_groups;
