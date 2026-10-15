# Fine-grid fitting replaces constrained subdivision

The per-cell moment solver and its tests were removed. The old
`subdivide_native.jl` command now stops with an error before writing output.
It must not produce another apparent higher-factor fit.

The old method fixed each source-to-parent contribution and constrained fine
moments to an interpolated coarse field. It could not fit independent fine
structure. See the [investigation](../../benchmark/continuity-factor-investigation.md).
Existing published files have not changed.

## Run a real fine-grid fit

Use a saved continuity study, not a native `part.jls` export directory. The
study must contain `countries.jls`. Its trial must contain `candidate.jls`,
`settings.csv`, and the saved border mask and weights. Supply source Arrow
files named `country-CODE-resRESOLUTION.arrow` for all study countries.

```sh
CONTINUITY_OUTER_STEPS=4 julia --threads=8 --project=examples/uk-h3 \
  examples/continuity/refine_grid.jl \
  COARSE_STUDY COARSE_TRIAL SOURCE_DIRECTORY NEW_OUTPUT 6 5
```

The last argument is a factor relative to the saved target grid. For example,
use 5 with a factor-1 study to get factor 5. The source resolution is separate.
Native H3-6 sources can replace the coarse H3-5 sources. No source-to-parent
flow is retained as a constraint. Use a new output directory. The command
requires oneAPI and does not resume or publish files.

## Method and checks

1. Divide the target geometry before fitting. Each country gets equal fine
   target capacities and its supplied source population. Scale explicit shared
   cell cuts to the fine grid. Keep the saved country border mask and weights.
2. Tune eta on the actual fine-grid baseline with `compact_tune`. Use compact
   all-pair plans and KA kernels. Keep the calibration and stage records.
   Reject a selected baseline above 1.25 times the support target.
3. Interpolate the coarse geographic means. Fit a balanced starting plan with
   the original fine distance cost plus the soft guide cost `-xyz' * centres`.
   This guide is only for initialization. It is not a final constraint.
4. Run the continuity optimizer on the fine grid with the selected country
   etas. Use the original fine distance cost, continuity terms, and fold terms.
   There is no fixed coarse flow, coarse moment, or coarse support mask.

Internal and fold strengths scale by the relative factor squared. Border
scale increases by the factor. Fold smoothing area decreases by the factor
squared. Eta is selected again, not copied from the coarse country table.
The optimizer starts at step 1, not the coarse checkpoint's resume step.

Source and target mass checks and the saved distortion guards remain active.
A failed seed stops the run; it does not trigger a constrained subdivision.
The runner writes compact checkpoints and final orientation diagnostics. It
writes `research-fit-complete.txt`, not a publication marker or native export
parts. Audit sharpness, folds, borders, and labels before a separate export.
A completed run does not certify visual quality or a global optimum.

The all-pair method can be expensive at planet scale. No planet run was made
to test this correction. Small CPU and oneAPI tests check that a fine fit can
change coarse allocations and create previously absent source-to-parent links:

```sh
CONTINUITY_GPU_TEST=1 julia --threads=8 --project=examples/uk-h3 test/refine_grid.jl
```
