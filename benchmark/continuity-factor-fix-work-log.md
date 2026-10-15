# Fine-grid factor correction work log

## 2026-10-15: scope

The user requested a code correction, with no dataset rerun. The preceding
[investigation](continuity-factor-investigation.md) found fixed coarse flows
in the H3-6 higher-factor path. No published files, H3-MON files, or production
`src/` files were changed during this correction. Only small test fits ran.

## Implementation

- Removed `target_subdivision.jl` and its moment-preservation tests. The old
  `subdivide_native.jl` command now fails before it writes output. It directs
  callers to the fine-grid runner instead of silently changing the CLI inputs.
- Updated `refine_grid.jl` to create fine target geometry before fitting. It
  uses compact all-pair plans with KA and oneAPI, not dense host cost matrices.
- Added fine-grid eta calibration. Reject selected baselines above 1.25 times
  the support target. Keep calibration plans and stage reports for inspection.
- Kept coarse geographic interpolation only as a soft initialization cost.
  The final objective has no fixed source-to-parent flows or coarse moments.
- Rebuilt the fine continuity graph. Retained country border masks and weights,
  scaled shared-cell cuts, and retained the earlier penalty scaling rules.
- Reset the fit step to 1. Retained mass checks and distortion guards. The
  runner writes a research marker only, not a publication marker.
- Allowed new source IDs and populations. The file-runner test uses five
  native H3-6 sources instead of the four coarse fixture sources.

The new runner takes a saved continuity study and source Arrow files. It does
not take the old native export-part directory. This is an intentional format
boundary: an export part has no complete continuity objective or border mask.
See [run instructions](../examples/continuity/target_subdivision.md).

## Tests and review

The first CPU run found that a numeric-only settings dictionary could not hold
selected country etas. The settings copy now uses `Dict{Symbol,Any}`.

At 15:16 UTC, the reversed-map regression passed on CPU and oneAPI. It checks
that the fine plan changes coarse allocations, adds previously absent coarse
connections, and matches the independent fine baseline when penalties are off.

The final expanded tests passed:

- `test/refine_grid.jl`: 2 removed-command checks, 14 geometry and settings
  checks, 18 CPU fit checks, and 14 oneAPI fit checks. These include border
  adjacency, cut masks, native source replacement, and output safeguards.
- `test/compact.jl`: 114 checks each on CPU and oneAPI, including continuity
  updates and per-country eta settings.

Logs are under `output/continuity-factor-fix/`. Tests use the UK example Julia
project, eight Julia threads, four BLAS threads, and the legacy oneAPI driver.
The final diff review removed a redundant tolerance variable. No core solver
or installed package was changed.

## Limits

This correction restores the fitting model. It does not establish planet-scale
runtime, convergence, or visual quality. All-pair fine-grid optimization can be
expensive. The runner does not resume or publish a planet dataset. A later run
must audit support, borders, orientation, source coverage, and labels before
export. Existing published factors 2, 3, and 5 remain constrained subdivisions
until that separate rerun and publication work is complete.
