# Native-source planet baseline

This experiment changes H3-5 sources to native H3-6 sources. It keeps the old
factor-1 target grid. It is not a new whole-planet border-optimization pass.
The reference map supplies the coarse flows, target centres, and city names.

## Method

1. Group native source population by H3-5 parent within each country.
2. Project the reference flows onto the new parent masses and uniform target
   masses. Use a sparse graph with nearby target cells. Add links between
   disconnected components when their source and target mass totals differ.
3. Split each parent flow between its native children. The parent-to-target
   flow is a fixed marginal in this solve. Use KA and oneAPI. Stop cooling when
   the 99.5% support ratio reaches the reference country's ratio, or keep the
   last valid temperature stage.
4. Keep rows from both source and target mass rankings. Normalize sources and
   check target masses again. Limit the target-centre shift from row selection
   to 2 km. Try stricter row retention if a check fails.

If the source split fails, the runner can distribute each parent flow in
proportion to native child population. It marks that country `inherited`, not
`optimized`. This fallback has correct masses but can be broad. A failure of
the parent projection leaves the country incomplete.

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
skips completed countries. The completion marker covers the requested country
list only. A planet publisher must separately check coverage of all native
sources and all countries. This runner does not publish files or alter H3-MON.

Run `test/native_hierarchy.jl` with the example Julia project. Set
`CONTINUITY_GPU_TEST=1` to also run the oneAPI checks.
