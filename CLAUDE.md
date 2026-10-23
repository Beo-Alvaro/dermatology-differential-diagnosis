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
- Power BI Modeling MCP server (Microsoft, from the VS Code extension
  `analysis-services.powerbi-modeling-mcp` v1.0.0) is registered in the
  project `.mcp.json`. That file is gitignored, because its path is
  machine-specific.
  - It runs with `--start --accept-eula`. The owner accepted the licence on
    2026-10-23.
  - Update the path when the extension updates, because the version is in the
    folder name.
  - Write confirmations are OFF by default in this version, so back up the
    project folder before edits.
  - It edits the model only (measures, relationships, tables), not report
    visuals.
  - Power BI Desktop must have `powerbi/dermatology.pbip` open.
    - Its port changes every time Desktop restarts, so reconnect with
      `ListLocalInstances`.
  - MCP edits don't mark the file as changed, so Ctrl+S does nothing.
    Save with File → Save As over the same file instead, then check that
    the file's timestamp on disk changed.
- Scripts were tested on PostgreSQL 16 and 18.6. They use domains, generated
  columns and jsonb, which work on 12+.

## Repo layout

```
CLAUDE.md
README.md              question -> approach -> findings -> limitations
data/dermatology.csv   raw Kaggle download, renamed. Never edit it.
sql/00-06_*.sql        pipeline (below)
excel/                 EDA workbook + BUILD_GUIDE.md (COUNTIFS tie-out)
powerbi/
  dermatology.pbip           Power BI Project: open this in Desktop
  dermatology.SemanticModel/ model as TMDL text (tables, relationships, DAX)
  dermatology.Report/        report as PBIR JSON (one file per page and visual)
  BUILD_GUIDE.md             model, DAX, pages
  backup/                    local safety copies (gitignored)
docs/                  screenshots for the README
```

The report is a Power BI Project (.pbip), not a .pbix, so the model and
report are plain text that git can diff. `.pbi/cache.abf` (imported data)
and `.pbi/localSettings.json` are gitignored, so after a fresh clone, open
the .pbip and click Refresh to reload from the `derm` database.

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

Done:
- Pipeline 00-06 runs on the real Kaggle CSV with 14 PASS.
- README draft written with real findings.
- Repo under git.
- Excel workbook `excel/dermatology_eda.xlsx` built: 1,925 live formulas, 0
  errors. The tieout sheet says PASS (224 prevalence cells + Q1 profile match
  SQL).
  - It was generated by a Python/openpyxl script kept outside the repo (the
    owner approved Python for this one task), then calculated in real Excel.
  - The file itself is plain Excel. `excel/BUILD_GUIDE.md` explains every
    formula.
  - Lookups use XLOOKUP (owner's choice, for readability), so the workbook
    needs Excel 2021/365. Median uses a single-IF `MEDIAN(IF(...))`.
  - Gotcha for future edits: a whole-table reference must be stored as
    `derm[]` (Excel shows `derm`). Written bare, it gives #NAME?.

1. Build the Power BI report (4 pages) from `powerbi/BUILD_GUIDE.md`. Check
   that DAX matches the SQL views at the default 50-point cutoff.
   - Done by the owner:
     - Step 1: 8 tables loaded and renamed; saved as `powerbi/dermatology.pbix`.
     - Step 2: the 6 relationships, `fact_findings[disease_id]` hidden,
       `age_band` sorted by `age_band_sort`, `feature_name` by `feature_id`.
       Verified through the MCP on 2026-10-23 (count test: PSO 3,584 fact
       rows, total 11,712).
   - Done by Claude through the Modeling MCP (2026-10-23):
     - Backup before edits: `powerbi/backup/dermatology_before_mcp.pbix`
       (gitignored).
     - `Sharp Gap` what-if table: `GENERATESERIES(0, 100, 5)`, column
       `Sharp Gap` with the `ParameterMetadata` extended property, and the
       measure `[Sharp Gap Value]` (SELECTEDVALUE, default 50).
     - `_Measures` table (calculated, one hidden placeholder column) with
       the 14 measures from BUILD_GUIDE section 3. They're in display
       folders 1-4 by page and have descriptions.
     - Validated against SQL: patients 112/61/72/49/52/20; Q1 profile and
       Q5 atypical counts match exactly. PSO × thinning signature is 95.64
       (SQL 95.6). Verdicts match `vw_q3_pair_summary` for all 15 pairs.
       Biopsy-dependent pairs are 1 at 50 and 4 at 80.
   - The owner saved the report as a Power BI Project:
     `powerbi/dermatology.pbip`, with `dermatology.Report/` (PBIR: one JSON
     file per page and visual) and `dermatology.SemanticModel/` (TMDL).
     The .pbip is now the report in the repo. The stale model-only .pbix
     was moved to `powerbi/backup/dermatology_model_only_stale.pbix`.
   - Pages: built by Claude on 2026-10-23 at the owner's request (this
     replaces the earlier "owner builds by hand" plan). Claude wrote the
     PBIR JSON directly, and the owner checked every page against SQL in
     Desktop.
     - 5 pages: Overview, Signature heatmap, Disease detail (hidden
       drill-through on `disease_name`), Look-alike pairs, Feature explorer.
       Readable folder names, e.g. `pages/overview/visuals/overview-bar-patients/`.
     - Disease colours (Okabe-Ito, colour-blind safe) are set per bar:
       PSO #0072B2, SD #E69F00, LP #009E73, PR #CC79A7, CD #56B4E9,
       PRP #D55E00.
     - The heatmap has totals off. At the grand total, `Prevalence Others %`
       is blank, so `Signature Strength` would show plain prevalence there.
     - The red-flag table shows k = 1 and k = 2 together (column `k`).
       BUILD_GUIDE's "synced min_score slicer" can't work: slicer sync
       groups only sync across pages, not on one page.
     - `Biopsy-Dependent Pairs` is blank (not 0) below a cutoff of 20.
   - Editing PBIR files: close Desktop first. It doesn't watch files and
     overwrites them on save. Backup before the pages:
     `powerbi/backup/pbip_before_pages/`.
   - PBIR gotcha: a single-value ("Single") slicer needs
     `data.numericStart` (e.g. `'50D'`) to display its value. With only the
     `general.filter` comparison, the filter applies but the slider shows
     its minimum (0). Desktop writes both when you set the slider by hand.
2. Screenshots: done 2026-10-23.
   - The owner exports the report with File → Export → Export to PDF to
     `docs/dermatology_report.pdf`.
   - Claude renders each PDF page to `docs/*.png` (overview,
     signature_heatmap, look_alike_pairs, feature_explorer), using Windows'
     built-in PDF renderer (Windows.Data.Pdf) from a PowerShell script kept
     outside the repo.
   - The README shows look_alike_pairs at the top and one image per
     question, and links the PDF.
   - Still to do: paste the Kaggle URL into the README's dataset credit.
3. GitHub: published 2026-10-23 as a public repo,
   https://github.com/Beo-Alvaro/dermatology-differential-diagnosis
   - gh CLI installed with winget, logged in as Beo-Alvaro.
   - `excel/dermatology_eda.xlsx` has local changes the owner hasn't
     committed, so GitHub has the earlier committed version.

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
