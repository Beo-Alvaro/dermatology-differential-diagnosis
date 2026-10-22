# Dermatology Differential Diagnosis: Data Analyst Portfolio Project

## What this project is

A portfolio project for data analyst roles. It showcases **SQL (PostgreSQL)** and
**Power BI**, with **Excel** for first-pass EDA. This is NOT a machine-learning
project: don't build classifiers. The goal is to explain the data, not predict it.

- Working title: *When Does the Biopsy Earn Its Keep?*
- Headline question: which of six look-alike skin diseases can be told apart from
  clinical findings alone, and which need a biopsy (histopathology)?
- Framing: decision support for a dermatology clinic, or an HMO reviewing when
  biopsies add the most value.

## Dataset

- Source: Kaggle, "Dermatology Dataset (Multi-class classification)" by
  olcaybolat1, a copy of the UCI Dermatology dataset (Ilter & Güvenir, 1998).
  License CC BY 4.0, so the README must credit the source.
- 366 rows, one per patient. The file has no patient ID.
- Column order: 33 findings (UCI attributes 1-33), then `age`, then `class`.
  - 10 clinical findings + 22 histopathological findings (from biopsy), each
    scored 0-3 (0 = absent, 3 = strongest).
  - `family_history` (UCI attribute 11) is 0/1. `age` is in years.
  - `class` 1-6: 1 Psoriasis (112), 2 Seborrheic dermatitis (61),
    3 Lichen planus (72), 4 Pityriasis rosea (49), 5 Chronic dermatitis (52),
    6 Pityriasis rubra pilaris (20).
- All six diseases share erythema and scaling, which is why they're hard to
  tell apart.

### Known data quirks (found by sql/02_profiling.sql)

- 8 missing ages, coded `?` (UCI original) or blank depending on the copy.
  The Kaggle copy in `data/` uses `?`. 4 of the 8 are chronic dermatitis patients.
- One psoriasis patient (row 120 in UCI order) has age 0. It is treated as
  missing: the decision is commented in 03_clean.sql and recorded in `age_note`.
  After cleaning: 9 unknown ages, known ages 7-75.
- `eosinophils_in_the_infiltrate` only ranges 0-2. This is real, not an error.
- All other findings are clean integers 0-3. There are no exact duplicate rows.
- Source column names vary by copy. The UCI names have typos ("microabcess",
  "monoluclear inflitrate") and hyphens. The Kaggle header keeps
  "munro_microabcess" and shortens names (e.g. `eosinophils_infiltrate`).
  Staging uses corrected snake_case names. The load maps columns by
  position, so the CSV header spelling doesn't matter.

## Environment

- Windows, VS Code, PowerShell terminal.
- PostgreSQL 18 installed locally (EDB installer), `psql` on PATH.
- Database `derm`, user `postgres`. The password lives in
  `%APPDATA%\postgresql\pgpass.conf` (outside the repo), so psql doesn't
  prompt. Never commit a password. Use `psql -w` to fail fast instead of prompting.
- Power BI Desktop connects to `localhost`, database `derm`, in Import mode.
- Scripts were tested on PostgreSQL 16 and 18.6. They use domains, generated
  columns and jsonb, which work on 12+.

## Repo layout

```
CLAUDE.md
README.md              question -> approach -> findings -> limitations
data/dermatology.csv   raw Kaggle download, renamed. Never edit it.
sql/00-06_*.sql        pipeline (below)
excel/                 EDA workbook + BUILD_GUIDE.md (COUNTIFS tie-out)
powerbi/               .pbix report + BUILD_GUIDE.md (model, DAX, pages)
docs/                  screenshots for the README
```

## Running the pipeline

Always run from the repo root, because `\copy` reads `data/dermatology.csv`
relative to the current folder:

```powershell
createdb -U postgres derm                          # first time only
psql -U postgres -d derm -f sql/00_run_all.sql
```

`00_run_all.sql` stops at the first error. It runs 14 validation checks, and
all of them must say PASS (a FAIL raises an error and stops the run). Then it
builds the analysis views.

## Pipeline layers

| Script | What it does |
|---|---|
| 01_staging | Creates schemas `staging` + `analytics`. `staging.raw_dermatology` stores every column as TEXT. The `row_num` identity (file order) becomes `patient_id`. |
| 02_profiling | Read-only profile of all columns, using jsonb unpivot: blanks, `?`, ranges, distinct values, missing ages by class, suspicious ages, duplicate rows. |
| 03_clean | Builds `analytics.dermatology_clean` with real types. Domain `analytics.finding_score` = SMALLINT NOT NULL 0-3. CHECKs on age 1-120, family_history 0/1, disease_id 1-6. Bad data fails loudly. |
| 04_model | Builds the star schema (below). |
| 05_validation | 14 PASS/FAIL checks (row counts per layer, 32 findings per patient, round trip vs raw CSV, class counts), plus a prevalence query for tying out against Excel. |
| 06_analysis_views | 11 `vw_` views: a base prevalence view (`vw_disease_feature_prevalence`, rounded to 1 dp once) plus 2 views per question (`vw_q1_*` ... `vw_q5_*`). |

### Star schema (`analytics`)

- `dim_disease`: disease_id 1-6, disease_name, disease_abbrev (PSO, SD, LP,
  PR, CD, PRP, for pair labels like "PSO vs LP").
- `dim_feature`: 32 rows (10 Clinical, 22 Histopathological).
  - `feature_id` is the UCI attribute number.
  - `feature_key` is the clean column name.
  - `feature_name` is the display name.
  - `feature_group` is 'Clinical' or 'Histopathological'.
- `patients`: patient_id, disease_id, age, age_band, age_band_sort, age_note,
  has_family_history.
  - Age bands: Under 18 / 18-29 / 30-44 / 45-59 / 60+ / Unknown (sort 1-6).
- `fact_findings`: 11,712 rows (366 × 32), PK (patient_id, feature_id).
  - Columns: patient_id, feature_id, disease_id, score.
  - `is_present` is a generated column: 1 if score >= 1, else 0.
  - Built by unpivoting with `jsonb_each_text` joined to `dim_feature` on
    `feature_key`.
- `fact_findings.disease_id` is denormalized for SQL convenience only.
  - Power BI relationships: dim_disease → patients → fact_findings, and
    dim_feature → fact_findings.
  - No direct dim_disease to fact_findings link. Hide `fact_findings[disease_id]`.

## Analysis plan: five questions

Metric definitions (use these exactly, and document them in the README):

- **Prevalence**: % of patients in a group with score >= 1, i.e. `AVG(is_present)`.
- **Signature strength**: prevalence in a disease minus prevalence among all
  other patients, in percentage points.

1. **Who's in the data?**
   - Disease mix, age bands, median age (`PERCENTILE_CONT`), family-history
     rate by disease, and where the missing ages fall.
   - Power BI page: Overview.
2. **What makes each disease distinctive, and which findings don't help?**
   - Top 5 findings by signature strength per disease, using
     `RANK() OVER (PARTITION BY disease ...)`.
   - Non-discriminators: the findings with the smallest spread in prevalence
     across the six diseases.
   - Power BI page: Signature heatmap, with drill-through to one disease.
3. **Headline: which diseases can be told apart clinically, and which need a biopsy?**
   - Self-join disease pairs: 15 pairs × 32 features = 480 rows. Gap = |prevalence A − prevalence B|.
   - "Sharp" means gap >= 50 points. Make the 50 a Power BI what-if parameter.
   - Report the SHARE of clinical features (out of 10) and of histopathological
     features (out of 22) that are sharp. Normalize by group size.
   - Low clinical share + high histopathological share = biopsy-dependent pair.
   - Verdict rule: "Clinically separable" if >= 1 clinical finding is sharp,
     else "Biopsy-dependent" if >= 1 histo finding is sharp, else "Hard even
     with biopsy". At 50: only SD vs CD is biopsy-dependent. At 80: plus
     PSO vs SD/PR/CD.
   - Power BI page: Look-alike pairs scatter.
4. **Which findings point almost entirely to one disease?**
   - Among patients with the finding at score >= k, a red flag is when one
     disease is >= 80% of them. Compare k = 1 vs k = 2.
   - A red flag also needs >= 10 patients with the finding (min_support).
     None was blocked by this at k = 1 or 2; it is a guard.
   - Power BI page: Feature explorer, 100% stacked bar.
5. **How many patients are atypical?**
   - Atypical = missing at least one of their disease's top 3 signature
     findings (fewer than 3 of 3). Tuned on the counts: "fewer than 2 of 3"
     flagged only 2 of 366 patients. "Fewer than 3" flags 55 (15%), mostly in
     SD, CD and PR. Top 3 uses ROW_NUMBER, so ties go to the lower feature_id.
   - Report count and % by disease, on the Feature explorer page.

Sanity check: the rankings should rediscover textbook markers, e.g. Munro
microabscess → psoriasis and band-like infiltrate → lichen planus. If they
don't, suspect the pipeline before the data.

## Next steps

Done: pipeline 00-06 runs on the real Kaggle CSV with 14 PASS, and
the README draft is written with real findings.

1. Build the Excel EDA workbook (`excel/BUILD_GUIDE.md`) and tie it out
   against the query at the end of 05_validation.
2. Build the Power BI report (4 pages) from `powerbi/BUILD_GUIDE.md`. Check
   that DAX matches the SQL views at the default 50-point cutoff.
3. Add Power BI screenshots to `docs/` and the README. Paste the Kaggle URL
   into the README's dataset credit.
4. Put the repo under git and publish it to GitHub.

## Conventions

- PostgreSQL style:
  - uppercase keywords and snake_case names;
  - CTEs over nested subqueries, table aliases;
  - a comment header on every file (purpose, how to run).
- Scripts:
  - numbered and re-runnable (`DROP ... IF EXISTS`);
  - listed in 00_run_all.sql;
  - after any change, rerun the full pipeline, and every check must still PASS.
- Never edit `data/dermatology.csv`. Every fix happens in SQL, with the
  decision commented.
- Analysis outputs are views in `analytics` with the `vw_` prefix.
- Scope is SQL, Power BI and Excel. Ask before adding Python or other tools.

## Working with the owner

- This is a learning project as well as a portfolio piece. The owner must be
  able to explain every query in an interview.
  - Briefly explain new SQL and DAX: what it does and why.
  - Prefer readable over clever, and point out trade-offs.
- Summarize proposed changes before any large rewrite.

## Limitations to keep in the README

- 366 patients from a single 1998 study in Turkey. The smallest group is 20 patients.
- Percentages describe this sample's mix, not real-world prevalence or
  diagnostic odds. This is not a diagnostic tool.
- There are no dates, locations or costs, so no time intelligence and no cost
  claims.
- Patterns in the findings show association, not cause.
