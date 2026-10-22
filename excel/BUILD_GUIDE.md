# Excel EDA workbook: how it works

`excel/dermatology_eda.xlsx` is the first-pass EDA. It also checks the SQL pipeline independently: two tools, the same raw CSV, the same numbers. Every number is a live Excel formula. The only typed-in values are the lookup tables and the SQL results pasted for the tie-out, and both are shown in **blue**.

Open it and go to **tieout**. Cell C4 must say **PASS**.

**Needs Excel 2021 or Microsoft 365** (it uses XLOOKUP, MINIFS and MAXIFS). Older Excel shows `#NAME?`.

## Sheets

| Sheet | What it shows |
|---|---|
| `README` | Purpose, sheet guide, color legend, decisions |
| `data` | The raw CSV as an Excel Table named `derm` (366 rows), plus 3 formula columns |
| `lookup` | Disease codes 1-6 and age band boundaries (typed in) |
| `mix` | Q1: patients, median age, unknown ages and family history by disease; age bands; bar chart |
| `pivot` | The same disease × age band counts as a PivotTable |
| `scores` | EDA: patients at each score 0/1/2/3 for all 33 attributes |
| `prevalence` | % of each disease's patients with each finding (score ≥ 1), all 32 findings |
| `tieout` | Excel minus SQL for 224 prevalence cells and the Q1 profile. All differences must be 0 |

## The formulas, sheet by sheet

### `data`: an Excel Table and three formula columns

The data is an **Excel Table** named `derm` (Insert → Table). That allows **structured references**: `derm[class]` means "the class column", and `[@age]` means "age in this row". They read better than `$AJ$2:$AJ$367`, and they grow automatically if rows are added.

| Column | Formula | What it does |
|---|---|---|
| `disease` | `=XLOOKUP([@class], diseases[class], diseases[disease_name])` | "Look up this row's class in the class column of the lookup table and return the name" |
| `age_clean` | `=IF(OR([@age]="?", [@age]=0), "", [@age])` | Blanks the 8 `?` ages and the 1 age of 0, the same decision as `sql/03_clean.sql`. That gives 9 unknown ages |
| `age_band` | `=IF([@age_clean]="", "Unknown", XLOOKUP([@age_clean], age_bands[min_age], age_bands[age_band], , -1))` | Match mode `-1` means "exact match, or else the next smaller value". So 37 finds the band starting at 30 and returns "30-44". The empty argument before it is the optional "if not found" value |

### `mix`: Q1 profile

| Number | Formula pattern | Note |
|---|---|---|
| Patients | `=COUNTIFS(derm[class], $A5)` | Counts rows where class = the code in column A |
| Median age | `{=MEDIAN(IF(derm[class]=$A5, derm[age_clean]))}` | An **array formula**. IF returns each age where the class matches and FALSE elsewhere; MEDIAN skips FALSE and the blank unknown ages and takes the middle value. There's no MEDIANIFS in Excel, so this is the standard workaround. The `{ }` braces mark it as an array formula |
| Min / max age | `=MINIFS(derm[age_clean], derm[class], $A5)` | MINIFS/MAXIFS skip the blank ages, so unknowns never count as 0 |
| Unknown age | `=COUNTIFS(derm[class], $A5, derm[age_clean], "")` | The `""` criterion counts blanks |
| Family history % | `=AVERAGEIFS(derm[family_history], derm[class], $A5)` | The column is 0/1, so its average *is* the rate |

The age band grid below uses `=COUNTIFS(derm[class], $A16, derm[age_band], C$15)`. Its totals must match the PivotTable.

### `prevalence`: one formula fills the whole grid

```excel
=COUNTIFS(derm[class], E$4, XLOOKUP($B5, derm[#Headers], derm), ">=1")
 / COUNTIFS(derm[class], E$4)
```

Read it inside out:
1. `XLOOKUP($B5, derm[#Headers], derm)` looks for the name in B5 (e.g. `clubbing_rete_ridges`) along the table's **header row** and returns the **whole column** under it. Searching sideways across headers and returning a full column is something VLOOKUP can't do.
2. The first COUNTIFS counts patients whose class is E4 **and** whose score in that column is ≥ 1. The second counts all patients in class E4. Dividing gives the prevalence.
3. `$B5` locks column B and `E$4` locks row 4, so the same formula can be filled right across the 6 diseases and down the 32 findings.

Column B uses the **CSV header spelling** (e.g. `munro_microabcess`), because XLOOKUP looks up those exact names.

### `scores`: EDA of the 0-3 scale

`=COUNTIF(XLOOKUP($B5, derm[#Headers], derm), E$4)` counts patients at score 0, 1, 2 or 3. Each row must total 366, and a red fill means it doesn't. An amber **max** marks an attribute that never reaches 3: family history (0/1 by design) and eosinophils in the infiltrate (max 2, real data, not an error).

### `tieout`: proving Excel = SQL

- The **blue** block is the output of the last query in `sql/05_validation.sql`, pasted as values.
- Each difference is `=ROUND(ROUND(prevalence!E5*100, 1) - C8, 1)`: Excel's prevalence as a percentage rounded to 1 decimal place, minus SQL's. The outer ROUND removes floating-point dust (0.0000000001) so that "equal" is exactly 0.
- `C4 = IF(AND(224 cells compared, 0 mismatches, 0 Q1 mismatches), "PASS", "FAIL")`, with green or red conditional formatting.

### `pivot`

**Insert → PivotTable** from the `derm` table: rows `disease`, columns `age_band`, values Count of `patient_id`. Unlike formulas, a PivotTable does **not** update by itself. After changing data, right-click → **Refresh**.

## Interview talking points

- **Why Excel and SQL?** Two independent tools agreeing on 224 numbers is strong evidence that the pipeline didn't drop or distort data.
- **Why `age_clean` instead of editing `age`?** The raw values stay untouched and the cleaning rule is visible, the same principle as staging → clean in SQL.
- **Why XLOOKUP, not VLOOKUP?** VLOOKUP needs a hardcoded column number (`VLOOKUP(x, table, 2, FALSE)`), which silently breaks if a column is inserted. It can only search the leftmost column, and it defaults to approximate match. XLOOKUP names the lookup and return columns directly, and it defaults to exact match. Before XLOOKUP, analysts used `INDEX(return_col, MATCH(x, lookup_col, 0))` for the same reasons. That still works in every Excel version, which is the trade-off: this workbook needs Excel 2021 or 365.
- **Trade-off:** the pasted SQL values are a snapshot. If the pipeline changes, re-run the query and paste again.
