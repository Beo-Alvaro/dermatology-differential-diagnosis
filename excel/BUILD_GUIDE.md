# Excel EDA workbook guide

First-pass EDA in `excel/dermatology_eda.xlsx`, then a tie-out against the
SQL pipeline. The goal is two independent tools reaching the same numbers.

## 1. Load the data without touching the raw file

**Data → Get Data → From File → From Text/CSV** → `data/dermatology.csv` → **Load**.

Never open the CSV directly and save it. Excel would rewrite it, for example by changing the `?` ages. The raw file stays read-only. Power Query names the table after the file, so rename the query to `derm` to match the formulas below.

In Power Query (Transform Data), optionally:
- Replace `?` with null in `age` and set its type to Whole Number.
- Add a `disease` column from `class` (1 Psoriasis, 2 Seborrheic dermatitis, 3 Lichen planus, 4 Pityriasis rosea, 5 Chronic dermatitis, 6 Pityriasis rubra pilaris).

## 2. Sheets

| Sheet | Contents |
|---|---|
| `data` | The loaded table (366 rows) |
| `mix` | PivotTable: rows `disease`, values Count of `class` and % of grand total. Should show 112 / 61 / 72 / 49 / 52 / 20 |
| `age` | PivotTable: rows `disease`, values Count / Min / Max / Average of `age`; a histogram of `age` |
| `prevalence` | The COUNTIFS grid below |
| `tieout` | Paste of the SQL grid next to the Excel grid, with a difference column |

## 3. Prevalence grid (COUNTIFS)

Prevalence = share of a disease's patients with the finding at score ≥ 1.

Lay out finding names down column A (A2:A33) and class numbers 1-6 across B1:G1. In B2:

```excel
=COUNTIFS(derm[class], B$1, INDEX(derm, 0, MATCH($A2, derm[#Headers], 0)), ">=1")
 / COUNTIFS(derm[class], B$1)
```

- `INDEX(derm, 0, MATCH(...))` returns the whole column whose header matches the finding name in A2, so one formula fills the grid.
- `$A2` locks the column and `B$1` locks the row, so fill right and down.

The A2:A33 names must match the **CSV header spelling** (e.g. `eosinophils_infiltrate`, `munro_microabcess`), not the cleaned SQL names. Copy them from the header row, skipping `family_history`, `age` and `class`.

Format as % with 1 decimal place.

## 4. Tie-out against SQL

Run the last query in `sql/05_validation.sql`. It prints the same grid with the same finding order, as % with 1 decimal place. Paste it into `tieout`, then compute `=ROUND(excel*100,1) - sql` for each cell. Every difference should be 0.0.

Spot checks:
- Psoriasis × clubbing of the rete ridges = 97.3%
- Lichen planus × band-like infiltrate = 100.0%
- Chronic dermatitis × fibrosis of the papillary dermis = 100.0%
