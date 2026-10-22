# Power BI build guide

How to build `powerbi/dermatology.pbix` (4 pages) on top of the `derm` database.
Run `sql/00_run_all.sql` first so every table and view exists.

## 1. Connect (Import mode)

**Home → Get data → PostgreSQL database**
- Server: `localhost`, Database: `derm`, Data connectivity mode: **Import**
- Sign in with the **Database** tab (user `postgres`)

Load these from the `analytics` schema:

| Table / view | Why |
|---|---|
| `dim_disease`, `dim_feature`, `patients`, `fact_findings` | Star schema: Overview + Signature heatmap via DAX |
| `vw_q3_pair_feature_gaps` | Look-alike pairs: 480 pair × finding gaps |
| `vw_q4_finding_disease_mix`, `vw_q4_red_flags` | Feature explorer: 100% stacked bar + red flag table |
| `vw_q5_patient_typicality` | Feature explorer: atypical patients |

In Power Query, rename the tables to drop the `analytics ` prefix.

## 2. Model

**Relationships** (Model view, all single direction, one-to-many):

| From (one side) | To (many side) |
|---|---|
| `dim_disease[disease_id]` | `patients[disease_id]` |
| `patients[patient_id]` | `fact_findings[patient_id]` |
| `dim_feature[feature_id]` | `fact_findings[feature_id]` |
| `dim_feature[feature_id]` | `vw_q3_pair_feature_gaps[feature_id]` |
| `dim_feature[feature_id]` | `vw_q4_finding_disease_mix[feature_id]` |
| `dim_disease[disease_id]` | `vw_q5_patient_typicality[disease_id]` |

- **Do not** relate `dim_disease` to `fact_findings` directly. Filters already reach it through `patients`, and a second path would make the model ambiguous.
- **Hide** `fact_findings[disease_id]` (right-click → Hide in report view). It's a denormalized copy for SQL only.
- **Sort** `patients[age_band]` by `patients[age_band_sort]` (select column → Column tools → Sort by column).
- Sort `dim_feature[feature_name]` by `dim_feature[feature_id]` so findings keep UCI order.

**What-if parameter** for the "sharp" cutoff: Modeling → New parameter → Numeric range.
- Name `Sharp Gap`, min 0, max 100, increment 5, default 50.
- This creates the table `'Sharp Gap'` with the measure `[Sharp Gap Value]` and adds a slider.

## 3. DAX measures

Create a blank table called `_Measures` (Enter data → OK) to hold them.

```DAX
-- ---------- Overview ----------
Patients = COUNTROWS ( patients )

Median Age = MEDIAN ( patients[age] )          -- MEDIAN skips blanks (unknown ages)

Unknown Ages =
CALCULATE ( COUNTROWS ( patients ), ISBLANK ( patients[age] ) )

Family History % = AVERAGE ( patients[has_family_history] )   -- 0/1 column, so the average is the rate

-- ---------- Signature heatmap ----------
-- Prevalence: share of patients in the current filter with score >= 1.
Prevalence % = AVERAGE ( fact_findings[is_present] )

-- Prevalence among everyone NOT in the selected disease(s).
-- VALUES grabs the disease(s) currently on the row/column; REMOVEFILTERS
-- drops the disease filter, then the NOT IN filter keeps everyone else.
Prevalence Others % =
VAR CurrentDiseases = VALUES ( dim_disease[disease_id] )
RETURN
    CALCULATE (
        [Prevalence %],
        REMOVEFILTERS ( dim_disease ),
        NOT patients[disease_id] IN CurrentDiseases
    )

Signature Strength (pts) = ( [Prevalence %] - [Prevalence Others %] ) * 100

-- ---------- Look-alike pairs (uses the what-if parameter) ----------
-- Share of a group's findings whose gap clears the slider value.
-- Dividing by the group's own count normalizes 10 clinical vs 22 histo.
Sharp Clinical Share =
VAR Cutoff = [Sharp Gap Value]
RETURN
    DIVIDE (
        CALCULATE (
            COUNTROWS ( vw_q3_pair_feature_gaps ),
            vw_q3_pair_feature_gaps[feature_group] = "Clinical",
            vw_q3_pair_feature_gaps[gap_pts] >= Cutoff
        ),
        CALCULATE (
            COUNTROWS ( vw_q3_pair_feature_gaps ),
            vw_q3_pair_feature_gaps[feature_group] = "Clinical"
        )
    ) + 0                                                   -- + 0 shows 0% instead of blank

Sharp Histo Share =
VAR Cutoff = [Sharp Gap Value]
RETURN
    DIVIDE (
        CALCULATE (
            COUNTROWS ( vw_q3_pair_feature_gaps ),
            vw_q3_pair_feature_gaps[feature_group] = "Histopathological",
            vw_q3_pair_feature_gaps[gap_pts] >= Cutoff
        ),
        CALCULATE (
            COUNTROWS ( vw_q3_pair_feature_gaps ),
            vw_q3_pair_feature_gaps[feature_group] = "Histopathological"
        )
    ) + 0

Biopsy Lift (pts) = ( [Sharp Histo Share] - [Sharp Clinical Share] ) * 100

-- Same rule as vw_q3_pair_summary, but driven by the slider.
Pair Verdict =
SWITCH (
    TRUE (),
    [Sharp Clinical Share] > 0, "Clinically separable",
    [Sharp Histo Share] > 0,    "Biopsy-dependent",
    "Hard even with biopsy"
)

Biopsy-Dependent Pairs =
COUNTROWS (
    FILTER (
        VALUES ( vw_q3_pair_feature_gaps[pair_label] ),
        [Pair Verdict] = "Biopsy-dependent"
    )
)

-- ---------- Feature explorer ----------
Atypical Patients = SUM ( vw_q5_patient_typicality[is_atypical] )

Atypical % = AVERAGE ( vw_q5_patient_typicality[is_atypical] )
```

Formats: the `%` and `Share` measures are Percentage with 1 decimal place; the `(pts)` measures are Decimal with 1 decimal place.

**Check against SQL:** with the slider at 50, `Pair Verdict` must match `vw_q3_pair_summary.verdict`. SD vs CD should be the only biopsy-dependent pair, and `Signature Strength (pts)` must match `vw_q2_signature_strength` to within 0.1. The SQL rounds prevalence first, so DAX can differ in the last decimal place.

## 4. Pages

### Page 1: Overview (Q1)
- Cards: `Patients`, `Median Age`, `Family History %`, `Unknown Ages`
- Bar chart: `dim_disease[disease_name]` × `Patients`
- 100% stacked bar: `dim_disease[disease_name]` × `Patients`, legend `patients[age_band]`
- Table: disease name, `Patients`, `Median Age`, `Family History %`, `Unknown Ages`

### Page 2: Signature heatmap (Q2)
- Matrix: rows `dim_feature[feature_name]`, columns `dim_disease[disease_name]`, values `Signature Strength (pts)`
  - Conditional formatting → Background color → diverging (min red, 0 white, max green)
- Slicer: `dim_feature[feature_group]`
- **Drill-through page "Disease detail"**: add `dim_disease[disease_name]` to the Drill-through well
  - Table: `feature_name`, `feature_group`, `Prevalence %`, `Prevalence Others %`, `Signature Strength (pts)`
  - Visual filter: feature_name → Top N 5 by `Signature Strength (pts)`
  - Card: `Atypical %` (Q5 for this disease)

### Page 3: Look-alike pairs (Q3, headline)
- Slider: `Sharp Gap` parameter
- Scatter: Values `vw_q3_pair_feature_gaps[pair_label]`, X `Sharp Clinical Share`, Y `Sharp Histo Share`
  - Top-left = biopsy-dependent (low clinical, high histo). Add an X = Y line via Analytics → constant lines, or a diagonal shape.
- Table: `pair_label`, `Sharp Clinical Share`, `Sharp Histo Share`, `Biopsy Lift (pts)`, `Pair Verdict`, sorted by lift
- Card: `Biopsy-Dependent Pairs`
- Text box: "At 50 points only SD vs CD needs a biopsy; slide to 80 and three psoriasis pairs join it."

### Page 4: Feature explorer (Q4 + Q5)
- Slicer: `vw_q4_finding_disease_mix[min_score]` (single select: 1 or 2)
- 100% stacked bar: axis `feature_name`, legend `disease_name`, values `n_patients`
- Table: `vw_q4_red_flags` filtered to `is_red_flag = 1`; columns `feature_name`, `top_disease`, `top_share_pct`, `n_with_finding`; add a `min_score` slicer synced with the one above
- Bar chart: `dim_disease[disease_name]` × `Atypical %`

## 5. Finish
- Use the same disease colors on every page (Format → Data colors), so psoriasis is always the same color.
- Save as `powerbi/dermatology.pbix`, export each page to `docs/` as PNG for the README.
