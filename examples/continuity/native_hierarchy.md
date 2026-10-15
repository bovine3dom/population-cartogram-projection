# Native-source planet baseline

This experiment changes H3-5 sources to native H3-6 sources. It keeps the old
factor-1 target grid. It is not a new whole-planet border-optimization pass.
The reference map supplies the coarse flows, target centres, and city names.

## Method

1. Group native source population by H3-5 parent within each country.
2. Adjust the reference flows to the new parent masses and uniform target
   masses. Transfer excess mass along target-grid paths. Each intermediate
   cell transfers its own source mixture before it receives mass. This limits
   long-distance changes. Connect separate grid components at their nearest
   geographic means. This deterministic preparation is not an entropy optimum.
3. Split each parent flow between its native children. The parent-to-target
   flow is a fixed marginal in this solve. Use KA and oneAPI. Stop cooling when
   the 99.5% support ratio reaches the reference country's ratio, or keep the
   last valid temperature stage.
4. Export every positive fitted contribution and check the country masses.
   Do not rank or remove contributions to reduce the export size.

If the source split fails, the runner can distribute each parent flow in
proportion to native child population. It marks that country `inherited`, not
`optimized`. This fallback has correct masses but can be broad. A failure of
the parent mass correction leaves the country incomplete.

The accepted country limits are source relative error at most `1e-10`, target
L1 error at most `1e-4`, and target maximum relative error at most `0.001`.
These are mass limits, not a guarantee of border quality. Measure border
separation and triangle orientation before publication.

A city name goes to the most populated native child of its old parent. If that
parent has no child in the same country, use the nearest native source and
record the fallback. This retains names, not exact city coordinates.

## Run

Use new output directories. Prepare native population with
`prepare_native6.jl`, then prepare the coarse guide cache:

```sh
julia --project=examples/uk-h3 examples/continuity/prepare_native_guides.jl \
  COARSE_INPUT.arrow REFERENCE.arrow GUIDES

H3_NATIVE_DEADLINE=2026-10-15T04:25:00 \
  julia --project=examples/uk-h3 examples/continuity/fit_native_sources.jl \
  GUIDES NATIVE_SOURCE_DIRECTORY OUTPUT
```

The deadline is UTC. On the P630, also set the legacy oneAPI driver environment
variable used by the other continuity benchmarks. The runner fits one country
at a time. Each successful country has `state.jls`, `projection.jls`, `fit.jls`,
`part.jls`, and `summary.csv`. A failed country has `error.log`.

The output manifest records input hashes. A resume checks those hashes and
skips completed countries. It also checks the all-positive export policy;
old row-selected checkpoints require a new output root. The completion marker covers the requested country
list only. A planet publisher must separately check coverage of all native
sources and all countries. This runner does not publish files or alter H3-MON.

## Binary export and geometry checks

`native_export.jl FIT NATIVE_SOURCE_DIRECTORY GUIDES NEW_OUTPUT [FACTOR]`
checks all native sources and countries before it writes files. It checks city
names against the guides, target coverage, shared-cell owners, country masses,
and physical target weights. It compares every transport column before and
after Arrow serialization. It does not publish to H3-MON.

The exporter uses dictionaries where they reduce the column size. Population
uses Float32 only when every source value is exactly representable; otherwise
it remains Float64. Density uses Float32, with measured relative error at most
`6e-8`. The H3 halves remain UInt32. Use a dictionary-capable Arrow reader.
This changes storage, not the fitted transport. Outputs are ordinary Arrow
IPC files. There are no per-batch replacement dictionaries or optional export
row reductions. The server keeps its existing compression policy.

`native_quality.jl FIT GUIDES FACTOR BORDER_CSV NEW_OUTPUT` measures support,
source spread, target-mean changes, triangle orientation, and edge separation.
It excludes shared target positions and false country contacts from the edge
graph. Compare these results before publication. A mass check alone does not
establish good geometry. File size alone does not establish a phone memory
limit. See [native publication](native_publication.md) for separate staging and
binary checks.

Run `test/native_hierarchy.jl` with the example Julia project. Set
`CONTINUITY_GPU_TEST=1` to also run the oneAPI checks. The binary export and
geometry tests are `test/native_export.jl` and `test/native_quality.jl`.
