# Build an OWID layout from three data inputs

## Status

The Julia command below starts from Kontur, Natural Earth, and original OWID.
It does not read saved layouts, saved assignments, or Python output files.
The saved layout and H3-MON exports have not changed.

This is the current reviewed layout baseline. The H3-MON exports are separate.
The tag `owid-clean-layout-baseline-v1` preserves this state.
[Open the review](../examples/auto-cartogram/results/owid-clean-build/index.html).
[Compare with the saved map](../examples/auto-cartogram/results/owid-clean-build/comparison/index.html).

## Run

Use Julia 1.12 and the checked-in package manifest. From the repository root:

```sh
julia --project=owid-layout -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

julia --project=owid-layout owid-layout/bin/build.jl \
  /path/to/kontur_h3.arrow \
  make-lookup-table/population-data/country-boundaries/ne_10m_admin_0_map_units.geojson \
  data/cartogram.csv \
  output/auto-cartogram/owid-clean-new

julia --project=owid-layout owid-layout/bin/review-group-resize.jl \
  output/auto-cartogram/owid-clean-new/layout \
  output/auto-cartogram/owid-clean-new/layout/components.csv \
  output/auto-cartogram/owid-clean-new/sources/polygons.geojson \
  output/auto-cartogram/owid-clean-review-new
```

Use new output directories. The build records data, code, policy, and dependency
hashes in `build.json`. A failed fit does not produce final layout cells.
The renderer writes HTML and SVG directly in Julia.

To compare two completed layouts without using either one as a fitting input:

```sh
julia --project=owid-layout owid-layout/bin/compare-layouts.jl \
  output/auto-cartogram/julia-group-resize-v5/cells.csv \
  output/auto-cartogram/owid-clean-new/layout/cells.csv \
  output/auto-cartogram/owid-clean-review-new/comparison
```

The Kontur Arrow must have `h3` and `population` columns. H3 cells must be unique,
valid resolution-8 cells. Population must be finite and positive.
The Natural Earth input must be the admin-0 map-unit GeoJSON, not a different
boundary layer. OWID must use its original headerless `x,y,country_code` format.

## Processing steps

1. Split Natural Earth into polygons. Assign native Kontur cell centres with
   strict point-in-polygon tests. Record unmatched and ambiguous cells separately.
2. Join source polygons that share an exact boundary segment within `ADM0_A3`.
   Corner contact alone does not join source polygons.
3. Read original OWID. At duplicate coordinates, use the last row.
4. Split the three existing scope pools: Cyprus, Somalia/Somaliland, and
   Serbia/Kosovo. Use fresh population totals and source border geometry.
5. Find same-country artwork groups connected by edges or corners. Retain
   edge-connected child pieces as identity evidence, not separate tile budgets.
6. Match every scope. Assign unmatched source components to the nearest source
   anchor. Weak target groups share a nearby population pool. A scope with one
   artwork group receives its whole source population without an island match.
7. Allocate whole tiles within each scope. Keep at least one tile per existing
   group. Keep each scope total fixed after the three scope splits.
8. Scale separate groups. For small shared landmasses, scale the combined outline
   first, then fit the internal borders with exact counts. Use local coast edits
   for large connected landmasses. Place separate pieces without overlap.
9. Check counts, connectivity, shared borders, coast status, and internal water.

The fitting solver uses one thread, a fixed seed, and a fixed node limit. It does
not use elapsed-time limits. The package manifest pins the geometry and solver
libraries. Reproducibility across different package versions is not promised.

## Data and rules

There are three external datasets. Two small tables are part of the program:

- `config/country-codes.csv`: numeric and alpha-3 country codes.
- `config/scope-crosswalk.csv`: the three scope splits listed above.

These tables contain no island identities, coordinates, or saved tile budgets.
They are explicit rules, not extra population observations. The scope rules are
not sovereignty claims. No hand-written island identity overrides are read.

## Output and limits

The full input has 32,957,699 Kontur cells and 8,031,924,024 people. Source
preparation assigns 7,954,677,990 people to polygons. It leaves 77,246,034 people
in 289,198 cells unmatched. There are no ambiguous cells in this input. The
population totals match the earlier preparation. The large Antarctic polygon
is excluded because its longitude span exceeds 180 degrees. The manifest lists
excluded polygons. The Arrow input does not declare a population year.

The source-membership Arrow records the original component index for each H3
cell. Index 0 means unmatched; -1 means ambiguous. The component tables and
crosswalk identify the source geometry. Unmatched population is not silently
assigned to a country. Source scopes without OWID tiles are listed separately
in `layout/source-scopes-without-tiles.csv`.

This command adjusts populations within existing scope totals. It does not
reallocate all 54,967 world tiles according to new country population totals.
It does not add every absent scope that might qualify for one tile.

An artwork group is not always a physical island. Corner chains join all of
Japan and both main New Zealand islands. These groups receive one budget each.
The clean build therefore keeps their original internal proportions. It does
not recover the earlier child-piece edits from a saved map. These differences
are part of the current reviewed baseline.

Internal water inside edge-connected landmasses stays empty and enclosed.
There are 64 such cells in this input. Some of the original 172 enclosed empty
cells are gaps between separate pieces. These gaps can open to the sea when
pieces move. The clean output has 101 enclosed empty cells, including all 64
protected cells. Water never receives country tiles.

The automatic identity costs and nearest-source fallback still need review.
Determinism does not prove that every match is geographically correct. The
shared-outline solver has a bounded search and can reject an infeasible fit.
The layout-only command does not produce an H3-to-tile mapping or change H3-MON.
Use the [pipeline command](workflow.md) to add fitting and Arrow export.

## Work log

- Added Julia source preparation with explicit population accounting and an
  H3-to-source membership file. The full source run matches earlier totals.
- Added the Julia shared-outline solver and geometry-based scope splits.
- Matched all scopes from original OWID. Removed the need for old assignments.
- Fixed one-group scopes such as Azerbaijan: one group can represent several
  real polygons, so it must not require a single matching source polygon.
- Added tests for source boundaries, holes, ambiguity, shared-edge joins,
  duplicate inputs, deterministic partitions, and connected scope seeds.
  Added final checks for scope totals, group connectivity, and coast status.
  All 204 tests pass.
- Preserved the earlier reviewed maps. Added separate review images so that
  changes from original OWID are not confused with changes from the saved map.
- Ran the final raw-input command twice in separate processes. All 17 output
  files are byte-identical, including the source-membership Arrow, assignments,
  budgets, final cells, and build manifest. The published `repeatability.json`
  contains their hashes.
- Checked the rendered world, Indonesia, Borneo, the Philippines, and Japan.
  Borneo retains a common outline with internal country borders. The Philippines
  has three population groups. Hokkaido is larger than in the saved map; this
  is a known difference. The Malaysian peninsula and Singapore also have
  different coast outlines. This clean layout is now the reviewed baseline.
