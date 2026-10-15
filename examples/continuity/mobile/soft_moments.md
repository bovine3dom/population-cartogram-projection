# Bounded moment packing

This is an approximate export step after the native KA/oneAPI fit. It does not
run a new border pass. The CPU LP uses only existing transport edges. It can
change their weights and remove rows.

## Preserved values and allowed changes

The LP preserves source mass, target population, target geographic XYZ means,
and target population-density means. It keeps each city contribution and each
target's first source contribution. Sorting retained rows by their original
index preserves these city and navigation anchors.

The source mean target position can move inside a box. `FORWARD_TOLERANCE` is
in coarse grid coordinates; one coarse cell has width 2. The Euclidean bound
is at most `sqrt(2) * FORWARD_TOLERANCE`. The same coarse-unit limit applies at
every subdivision factor. The LP minimizes squared distance from the previous
source means within each block. It does not impose a support-count target.

`TARGET_RETAINED` protects that fraction of each target's original population
contributions. Those protected row weights cannot decrease. With target mass
fixed, target total variation is at most `1 - TARGET_RETAINED`. For complete
query values in a bounded range, this bounds the mean error as a fraction of
that range. Missing-value filtering and renormalization do not have the same
bound. Read `query-errors.csv`, including its lost-coverage counts.

A low-population source can change its distribution substantially while its
mean position stays in the box. Do not interpret the target variation bound
as a source variation bound. Reports give both. Keep the unreduced fit.

## Checks and failures

The final country checks require source relative error at most `1e-10`, target
relative mass change at most `1e-7`, geographic mean change at most 1 metre,
and relative density change at most `1e-6`. They also check the position box,
target variation, city rows, and navigation rows. The native binary exporter
checks coverage, labels, masses, and physical weights again after serialization.

A time-limited solution can be used only if all constraints pass and its
objective is no worse than the initial plan. The report counts these blocks
as nonoptimal. A failed numerical block keeps its original rows and weights.
The report records each failure. A country that fails the final checks is not saved.
A packing deadline leaves the output incomplete; it does not accept a partial
country. File size still does not establish a safe browser memory limit.

## Run

```sh
H3_PACK_DEADLINE=2026-10-15T04:10:00 OPENBLAS_NUM_THREADS=1 \
  julia --threads=2 --project=examples/continuity/mobile \
  examples/continuity/pack_native.jl \
  FIT FACTOR TARGET_RETAINED FORWARD_TOLERANCE NEW_OUTPUT
```

The deadline is UTC. Optional country codes after the output path limit a pilot.
The runner checks input hashes on resume. Its completion marker covers only
the requested country list. Use `native_export.jl` for the independent planet
coverage check, then use [lossless stream packing](stream.md) if the reader
supports replacement dictionaries.

Run `test/soft_moments.jl` with the mobile example Julia project.
