# Supported workflow

## Layout baseline

The current layout is the [clean build](clean-build.md).
[Open the world map](../examples/auto-cartogram/results/owid-clean-build/world.svg).
The tag `owid-clean-layout-baseline-v1` preserves the code and review files.
The SHA-256 of `examples/auto-cartogram/results/owid-clean-build/cells.csv` is:

```text
ecb5033efa791e51f6fd3aeb9f857ba74903341040642a60991938fa0f009629
```

The two full builds produced identical files. The mainland trials did not change
this layout. Their methods are in `research/mainland/`. The package does not load
them. To run their separate tests:

```sh
julia --project=owid-layout owid-layout/research/mainland/tests.jl
```

## One command from inputs to Arrow

Use Julia 1.12 and the checked-in manifest. Run from the repository root:

```sh
julia --project=owid-layout -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

julia --project=owid-layout owid-layout/bin/pipeline.jl \
  /path/to/kontur_h3.arrow \
  /path/to/ne_10m_admin_0_map_units.geojson \
  /path/to/cartogram.csv \
  output/my-cartogram
```

Use a new output directory. The command runs these stages:

1. Assign native population cells to source polygons.
2. Match source components to artwork groups. Resize the artwork groups.
3. Aggregate native cells by source component and H3 parent.
4. Fit each declared population pool separately with the existing solver.
5. Balance the sparse transport and check both population margins.
6. Write the mapping and population density as Arrow files.

The default H3 resolution is 5. The command uses the CPU. A full-world fit can
take a long time. The Julia API also accepts an explicit KernelAbstractions
backend: `fit_export(build, output; resolution=5, backend=...)`. Install and load
the backend package in your environment. The pinned project does not install
GPU backends. The program does not silently switch backends after an error.

No Python programs or saved identity assignments are used. Geometry and
optimization libraries are called through Julia.

## Other OWID-style cartograms

The workflow does not require 55,000 tiles or the full world. It accepts a
regional or world cartogram with this format:

- Headerless CSV rows: `x,y,country_code`.
- Integer square-grid coordinates. Input y increases down the screen.
- One common grid spacing, inferred from coordinate differences.
- Numeric country codes with an entry in the country-code table.
- Country scopes that can be matched to the Natural Earth source data.

At duplicate coordinates, the last row owns the tile. This preserves the
original OWID import rule. Output layout coordinates have unit spacing and
north-positive y. Arrow export uses `x = 2 * layout_x`, `y = -2 * layout_y`.

The country-code table has `alpha3,numeric` columns. The default table contains
ISO numeric codes. Export assigns separate categorical codes to other scopes. Codes must be unique.
Custom names must agree with the source scopes. This is not a general adapter
for subnational boundaries or non-square grids.

The default scope table describes the existing OWID combined-country pools.
A regional cartogram can omit these pools. Do not apply those rules blindly to
artwork with different scope definitions. Supply a different table, or disable
scope splits with `null`. A scope table has `source_scope,target_scope,pool`
columns. The current split algorithm supports one missing scope per pool.

Pass an optional JSON file as the fifth command argument:

```json
{
  "resolution": 4,
  "country_codes": "config/my-country-codes.csv",
  "scope_crosswalk": null,
  "node_limit": 100000
}
```

Paths in this file are relative to the working directory. Unknown options are
errors. Resolution must be between 0 and 8. Kontur must have unique, valid H3-8
IDs in `h3` and positive finite values in `population`. Natural Earth must use
the admin-0 map-unit GeoJSON schema. These source requirements are unchanged.

Country totals come from the input artwork. The build changes populations
within those totals. It does not add all missing countries or reallocate the
world tile budget. The layout solver has a bounded search. Some input shapes,
small budgets, or scope splits can fail. Failure does not produce an accepted
mapping.

## Population groups

Native component membership is retained before H3 aggregation. The key is
`(source component, H3 parent)`, not just the H3 parent. Two islands can share a
coarse H3 cell without sharing their fitting pool.

`layout/source-assignments.csv` maps source components to population pools.
`layout/budgets.csv` maps artwork groups to those pools. Usually a pool has one
artwork group. A weakly matched piece can share a nearby pool. The adapter uses
that recorded decision; it does not make a new country-wide assignment.
Same-country corner-connected artwork is one group. Thus a group is not always
one physical island. Japan, for example, is one artwork group in this baseline.

Each pool has equal population per tile. Different pools can have different
population per tile because tile counts are integers and country totals stay
fixed. Unmatched, ambiguous, and unrepresented source populations are reported
separately. They are not silently added to a represented country.

The full-world H3-5 adapter check produced 400,161 component/H3 fragments,
244 pools, and 54,967 tiles. It represented 7,953,748,242 people. It excluded
77,246,034 unmatched people and 929,748 people in unrepresented scopes. No native
cell was ambiguous in this input. The population year is not declared by the
input Arrow file.

## Output and checks

The output directory contains:

- `sources/`: geometry, native membership, and source audits.
- `layout/`: assignments, budgets, cells, and layout checks.
- `build.json`: layout completion and input, code, and policy hashes.
- `mapping/sources.csv` and `mapping/targets.csv`: fitting inputs.
- `mapping/population-audit.json`: represented and excluded populations.
- `mapping/raw-shards/`: raw fits, saved before CPU balancing.
- `mapping/shards/`: checked, balanced per-pool mappings.
- `mapping/mapping-job.json`: completion, hashes, and fitting checks.
- `mapping/h3-mon/cartogram_weights_hilo.arrow`: H3-to-tile mapping.
- `mapping/h3-mon/population_density_hilo.arrow`: density values.
- `mapping/h3-mon/population_density_hilo.json`: H3-MON display metadata.
- `mapping/h3-mon/checks.json`: export checks and file hashes.

The fit must retain every represented source population within `1e-9` relative
weight error. Target population error must be at most `1e-4` (0.01%), as in the
earlier planet pipeline. Both sets of export
weights must sum to one within `1e-9`. Any transport between different pools is
an error. Export occurs only after these checks pass.

Sparse balance can add support at up to four adjacent-tile steps inside a pool.
It cannot cross a pool boundary. Each support attempt has a limit of 50,000
iterations. It fails if it cannot meet the tolerance. It does not claim a new
minimum-cost solution. The numerical loop uses typed arrays. It does not access
DataFrame columns inside the iteration loop.

All raw fits are saved before the balance stage starts. Thus CPU balancing does
not delay the next GPU fit. A failed balance can resume from the raw checkpoints.
The job records its current phase and the time for each fit and balance.

The exported H3 parent can have fragments in several pools. Those fragments are
combined only after fitting and checking. `weight` is a fraction of represented
parent population. `weight_mean` is a fraction of tile population. Use
`weight_mean` to average density. Density is represented parent population
divided by the full H3 cell area in square kilometres, including water.

City names are not supplied by these three datasets. This workflow writes empty
label columns. GeoNames labels need a separate input and are not part of this
consolidation. Border-aware fitting is also outside this workflow.

## Resume fitting without rebuilding the layout

For an existing complete layout build:

```sh
julia --project=owid-layout owid-layout/bin/fit-mapping.jl \
  output/my-cartogram output/my-cartogram/mapping 5
```

If fitting stopped, use the same command with `--resume` after the resolution.
Resume checks the data, code, dependency, backend, and shard hashes. Changed
inputs require a new mapping directory. A completed job cannot be overwritten.
A failed layout build requires a new build directory.

The H3-MON files are not deployed automatically. Serve the `mapping` directory
as data, or copy the entire `h3-mon` directory to the H3-MON data root. Use:

```text
?data=h3-mon/population_density_hilo.arrow&cartogram=h3-mon/cartogram_weights_hilo.arrow
```

If you rename the `h3-mon` directory, also change the `cartogram` path in its
metadata JSON. Keep old exports until the new map has passed visual review.

## Validation

The initial supported Julia suite passed 254 tests. The separate mainland research suite
passes 36 tests. Regenerating the full-world layout with the consolidated code
produced the same `cells.csv` hash as the baseline above.

Real H3-5 fits for Malaysia, Brunei, and Fiji passed the population checks. Their
Arrow files loaded in headless H3-MON without page errors or failed requests.
The rendered image was inspected. Two regional runs produced identical mapping
Arrow files. [Open the checks and image](../examples/auto-cartogram/results/owid-supported-workflow/index.html).
This is a regional export check, not a new full-world deployment. The full-world H3-5 input adapter was checked separately.

To repeat the regional check with a completed world layout:

```sh
julia --project=owid-layout owid-layout/test/regional-mapping.jl \
  output/my-cartogram output/regional-check MYS BRN FJI

node owid-layout/test/h3-mon.mjs \
  /path/to/H3-MON output/regional-check output/browser-review \
  http://127.0.0.1:1983
```

The optional browser test needs a running H3-MON server, its Playwright package,
and Chromium. It intercepts data requests to serve the local export. It does not
copy files into H3-MON or change its defaults. This JavaScript test is not a build
stage. The data workflow remains Julia-only.

## Work log

- Selected the clean layout as the baseline. Kept all earlier review files.
- Removed the mainland trial methods from the supported package load path.
- Added explicit country-code and scope-table options for other artwork.
- Added the native-membership adapter and checked full-world H3-5 accounting.
- Added per-pool fitting, sparse balance, restart checks, and Julia Arrow export.
- Added tests for a custom regional cartogram, shared H3 parents, declared pools,
  population conservation, invalid weights, and interrupted jobs.
- Regenerated the world layout and confirmed that its cells are unchanged.
- Checked real regional Arrow files in headless H3-MON and inspected the image.
- Fixed excessive allocations in CPU balancing. Restored the earlier planet
  tolerance of `1e-4` and the 50,000-iteration limit per support attempt.
- Separated raw fitting from balancing. Added raw checkpoint and recovery tests.
