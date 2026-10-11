# Border-focused research

See `benchmark/continuity-work-log.md` for the time window and decisions.
All research outputs are separate from production H3-MON files.

## Compare with nearby internal edges

The local comparison uses internal target edges incident to either side of a
selected international seam. Report both baseline and candidate local distances.
A candidate must not appear successful merely because its internal jumps grow.
Per-pair CSV files include each border's own local comparison.

The experiments now save full plans in Julia Serialization files:
`baseline.jls` and `candidate.jls`. Candidate plans are saved after every outer
iteration. These files require a compatible Julia environment. They are not
H3-MON files. Sparse Arrow exports remain optional.

## Check source distributions, not only their centres

For independent source draws with unit-sphere positions `u` and `v`,

```text
E[||u-v||²] = 2 - 2 * dot(E[u], E[v]).
```

This quantity includes each target's source spread. The RMS chord distance,
multiplied by Earth radius, can be calculated without a dense geographic
source-to-source distance matrix. It is not a Wasserstein distance or a
geographic line length. Compare it across seams and across nearby internal
edges.

Two penalty forms are available:

- `mean`: squared distance between target means, as in the initial experiment.
- `distribution`: expected squared distance between independent source draws.

Each can use the original saturating penalty or an uncapped quadratic penalty.
The distribution form discourages a false improvement made only by averaging
distant populations together. The uncapped form is a diagnostic for genuine
mainland seams; it is not a proposed default for islands or false contacts.

## First sweep

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  OPENBLAS_NUM_THREADS=4 julia --threads=8 --project=examples/uk-h3 \
  examples/continuity/sweep.jl output/continuity/africa-h3-4 \
  output/continuity/africa-sweep-1
```

This uses the three existing H3-4 country extracts and caches a common baseline.
It tests both penalty forms, both saturation choices, and strengths 0.01, 0.1,
and 1. It allows up to 20 outer steps. Border share is 95%. The internal and
spread limits are relaxed to 25% to measure their influence. These are research
limits, not acceptance criteria for production.

`summary.csv` records ratios between border and local internal statistics.
`failures.log` retains failed solves. A failed configuration does not stop the
remaining configurations. Inspect each pair and its full distributions before
selecting a setting. The launch is bounded by the 19:01 UTC deadline.

## Balanced sweep and diagnostics

Pass `balanced` as the third argument to `sweep.jl` to give more weight to
internal edges. This tests border shares 0.1, 0.25, and 0.5, strengths 0.1 and 1,
and two internal objectives. One uses absolute source-distribution separation.
The other penalizes changes in the baseline internal mean-displacement field.
The cross-border term remains a source-distribution penalty in both cases.
It allows 40 steps and an internal-maximum increase of up to 100% for diagnosis.

`diagnostics.jl SWEEP_DIRECTORY TRIAL_DIRECTORY` writes orientation counts and
optimistic source-supply bounds. Orientation uses two triangles per complete
2×2 target block. Positive geographic area is opposite to the expected direction
of this downward-y grid. Areas below 1 km² in magnitude count as flat. This is a
fold diagnostic, not a proof of injectivity.

For the supply bound, count distinct border targets in one country. Their equal
masses determine how much country population must be assigned to the seam.
Select that much source mass in order of distance to the nearest source in the
other country. Ignore all other constraints. The resulting mean is a lower bound
on mean physical source separation for those targets. It is not a lower bound
on centre separation or on the median over edges. Repeated target contacts and
shared coarse H3 parents require care when interpreting it.

`prepare_global.jl GLOBAL_HILO.arrow OUTPUT_DIRECTORY RESOLUTION COUNTRY_CODES...`
prepares matched source inputs without repeating the expensive boundary extract.
It refuses to replace existing output. Native H3-5 checks avoid shared-parent
quantization at borders. Experimental sparse exports now weight shared H3 parents
by their country population fractions, so a line score is not counted twice.

## Folds and refined targets

`study.jl SOURCE_DIRECTORY OUTPUT_DIRECTORY GROUP RESOLUTION FACTOR fold|validate`
runs a controlled study. Groups are `africa`, `mali-burkina`, and `germany-poland`.
Each group has an explicit set of genuine international borders. The fold study
tests hinge-penalty strengths 0, 0.01, and 0.1. Positive triangle area above 1 km²
is penalized, with an area scale of 2,500 km². This is a soft penalty, not a
no-fold guarantee.

The study uses geometric-force costs calculated on the GPU without storing the
full cost matrix there. Host plans and objective checks remain dense. This
avoids transferring a new large GPU cost matrix for each outer step. Gradients
that differ only by source-only or target-only constants give the same optimum.
Both constants are removed to improve Float32 conditioning. Tests compare this
path with the dense solver.

Near convergence, Float32 dual potentials can stop changing before the strict
marginal test passes. A short primal matrix-scaling refinement then runs on
KA/oneAPI. It temporarily stores the candidate matrix on the GPU. It does not
use a CPU solver or change the specified tolerance. The default target marginal
L1 tolerance is 0.00001. The subdivision studies use 0.0001 to reduce solve time.
Both require maximum relative target error at most 0.001. Source masses remain
exact after row normalization. Warm starts retain dual offsets and any
primal-refinement correction.

For subdivision factor `f`, the study scales entropy by `1/f²` and internal
penalty weight by `f²`. This is an experimental discretization choice: the mean
squared difference across internal edges decreases with cell width squared.
Border weight is not multiplied by `f²`. Always compare with a fresh baseline
at the same settings. Subdivision preserves the OWID outline but reduces the
population that must fit in its one-cell-wide border strip.

Set `CONTINUITY_DEADLINE` to an ISO date and time in UTC. The runner checks it
between cases; also use a shell timeout for a hard stop. Set
`CONTINUITY_COMMIT_REPORTS=1` to commit each case's small CSV and Markdown report
under `benchmark/continuity-runs/`. Only those report paths are committed. Large
plans stay under the ignored output directory. Failed cases are logged.

## Full line previews

```sh
julia --project=examples/uk-h3 examples/continuity/export_trial.jl \
  SWEEP_DIRECTORY/countries.jls TRIAL_DIRECTORY NEW_PREVIEW_DIRECTORY
node examples/continuity/plot-lines.cjs NEW_PREVIEW_DIRECTORY
```

The exporter retains at least 99.999% of each source's assignment. It writes
separate baseline and candidate hi/lo Arrow files, a shared population-density
file, and full-plan target centres. Retained target means are normalized for
H3-MON. City labels are empty. These are isolated previews, not production files.

The plotter uses H3-MON's actual `strokeCoverage` and `projectStroke` functions.
It selects lines at the baseline median and 90th-percentile seam edges, then
uses identical cartogram coordinates for both fits. Blue points show source
scores. Red segments connect target means; they are not geographic paths.
Geographic extents match between each pair of panels. Component counts depend
on a score threshold and population coverage; fewer components alone do not
prove a better mapping. Transported population is reported as a conservation
check. Chromium runs headlessly and closes after the screenshot. No server starts.
