# OWID island budget audit

## Scope

Inventory only. Do not change OWID tiles or run another population fit yet.
Use the existing source component populations. Keep each OWID country's total
tile count fixed. Calculate component quotas from population shares, then use
largest remainders for integer budgets. Do not impose a minimum island tile.

Run from the repository root:

```sh
OPENBLAS_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1 \
output/auto-cartogram/geometry-env/bin/python \
  examples/auto-cartogram/audit_owid_budgets.py \
  data/cartogram.csv \
  output/auto-cartogram/world-dissolved/components.csv \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  /usr/share/iso-codes/json/iso_3166-1.json \
  output/auto-cartogram/owid-budget-audit-v3
```

Use a new output path for a repeat run. The CSVs retain full component IDs.
The source and target part ranks are separate; rank is not a matching rule.
The source panels show longitude and latitude, not equal-area geometry.

## Review results

The public report is `results/owid-budget-audit/index.html`. It includes the
full inventories, input hashes, 11 country panels, and 13 visually checked
example identities in `reviewed-examples.csv`. These example names and matches
are review annotations, not automatic output or approved transport groups.

Checked France, the UK, Italy, Japan, Indonesia, Russia, Malaysia, and the US
panels. Small corrections look useful for Corsica (4 tiles versus a quota of
2.2) and the Isle of Wight (4 versus 0.9). Sardinia is already close (11 versus
11.0). Sicily needs more tiles (26 versus 33.9).

Some corrections are large. Hokkaido has 193 tiles versus a quota of 34.6.
Honshu has 509 versus 703.6. Indonesian Borneo has 248 versus 115.7, while
Sumatra has 271 versus 374.0. Do not include these in a small local-edit trial.
Nearby small components still need explicit group assignments. These can
change the final group budgets.

## Input limits

- OWID has 54,978 rows and 54,967 unique coordinates. Eleven coordinates have
  both South Africa and Lesotho labels. The inventory uses the last row,
  Lesotho, as `review_gaps.py` does. Record all conflicting labels. Do not
  treat this inventory convention as a production ownership decision.
- ISO map-unit codes take priority over sovereign country codes. This keeps
  Reunion, for example, out of the metropolitan France population budget.
- There are 205 scopes with both tiles and source population, 51 source scopes
  without tiles, and three tile scopes without a direct source-code match.
  These are not all omitted territories. In particular, source codes SDS,
  PSX, and SAH need reviewed aliases for SSD, PSE, and ESH. No alias is guessed.
- Russia and Canada each have one four-connected OWID tile part. Not every
  source island or exclave can be identified from tile connectivity.
- Native population assignments use H3 centres. Unmatched centres and boundary
  points are excluded. The population year is not verified.

## Next bounded trial

Start with France. Assign the remaining small metropolitan components to
explicit represented groups. Then test transferring two Corsica tiles to
mainland France. Preserve the country total, island visibility, connectivity,
and existing borders. Keep all other countries fixed. Do not add a new layout
solver or a border-aware population fit to this trial.

## Work log

The first run stopped on the overlapping South Africa/Lesotho coordinates.
The audit now records the conflict instead of silently hiding it. A second
attempt could not render with the unavailable plotting package. Removed that
dependency; the panels use SVG and the existing ImageMagick command. The
successful output is `owid-budget-audit-v3`, with plain LF line endings in CSVs.
All 357 Python tests pass. Five new tests cover parts, exact budgets, tiny
components, overseas scopes, overlaps, unknown scopes, and unchanged input.
No layout, mapping, or H3-MON export changed.
