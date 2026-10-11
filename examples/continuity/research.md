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
fold diagnostic, not a proof of injectivity. `inspect_study.jl STUDY_DIRECTORY`
also records total positive area and the largest positive triangle. A count alone
can hide a large reduction in fold size.

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
at the same settings. Refined studies now use entropy continuation: solve at
64, 16, and 4 times the requested entropy, then solve at the requested value.
Each stage uses the preceding dual potentials. Intermediate target L1 tolerance
is 0.001; the final stage retains the specified strict tests. This does not
accept a higher-entropy result as the final mapping. These studies also test
Anderson acceleration of the dual potentials. A five-vector host calculation
proposes a potential update after each 50 GPU steps. Accept it only if the
measured marginal error improves by at least 10%. The final acceptance tests
are unchanged. This small host calculation does not replace the GPU reductions.

Subdivision preserves the OWID outline but reduces the
population that must fit in its one-cell-wide border strip.

Set `CONTINUITY_DEADLINE` to an ISO date and time in UTC. The runner checks it
between cases; also use a shell timeout for a hard stop. Set
`CONTINUITY_COMMIT_REPORTS=1` to commit each case's small CSV and Markdown report
under `benchmark/continuity-runs/`. Only those report paths are committed. Large
plans stay under the ignored output directory. Failed cases are logged.
Use `CONTINUITY_CASES=border0.25-fold0.01` to select a case without running the
full set. A comma separates multiple case names. Refined grids select this case
by default to limit run time. Set `CONTINUITY_CASES` to an empty string to run all
cases. `CONTINUITY_OUTER_STEPS` sets the step limit; its default is 30.

## Proximal step check

`proximal_study.jl BASELINE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY [FACTOR=1]`
tests smaller transport changes. It loads a complete matched baseline and checks
that its entropy matches the requested subdivision factor. Select cases with
`CONTINUITY_PROXIMAL_CASES=proximal0.1-fold0.01`. Its default step limit is 100.
`CONTINUITY_INTERIOR_LIMIT` changes the diagnostic internal-distance guard from
its default of 2 times baseline. A relaxed guard is not a production acceptance
rule. Set `CONTINUITY_INTERNAL_FORM=mean` to test internal mean differences while
keeping the full source-distribution penalty across borders. This separates
internal smoothness from source spread. A distribution penalty contains both;
scaling it by `f²` also increases its pressure to reduce spread.

The inner objective adds
`proximal * KL(plan || previous_plan)`. This changes its cost by
`-proximal * log(previous_plan)` and its entropy coefficient by `+proximal`.
Zero entries use the smallest normal positive Float64 value in this cost.
This permits moves from entries that became zero numerically. The outer
acceptance test still uses the original objective. The inner solve
still uses KA/oneAPI. This test uses dense GPU costs, not the matrix-free path.
It checks whether smaller changes reduce folds without moving the border gap
into the interior. A fixed-point test checks the cost and entropy signs.

## Country pose search

`pose_study.jl BASELINE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY` tries eight rotations
per country at 45-degree intervals. It rotates source coordinates only to make
starting transport plans. It does not rotate the OWID artwork or the exported
geographic coordinates. It tests combinations with the original cost and the
continuity objective. It saves the country plans and a small metrics table.

`pose_refine.jl BASELINE_STUDY_DIRECTORY POSE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY`
then fits selected starting plans against the original cost. Set
`CONTINUITY_POSES=0-0,270-270` for a two-country comparison. Angles follow the
country order in `countries.jls`. `CONTINUITY_STRENGTHS=1,10` selects strengths.
The default step limit is 100. Seeds must have the correct source and target
masses and pass the stated distortion guards. The original baseline remains
separate; `seed-metrics.csv` records the starting point for each fit.

## Coarse-to-fine starting fields

`refine_grid.jl COARSE_STUDY COARSE_TRIAL SOURCE_DIRECTORY NEW_OUTPUT RESOLUTION FACTOR`
interpolates a fitted coarse geographic field to finer target cells. It uses
continuous affine interpolation on coarse grid triangles within each country.
Near the edge it uses the nearest complete grid block. Thin parts with no complete
block use local finite differences. Edge extrapolation can still create folds;
the field and the balanced seed therefore have separate orientation reports. A new Sinkhorn solve assigns the
same source population to those geographic starting positions. A fresh standard
baseline is calculated at the same resolution and entropy. The final fit again
uses the original cost and fixed OWID targets. The source IDs and normalized
populations must match the coarse input.

This test is for the selected mainland cases. It does not define which internal
island cuts must remain. Do not apply its interpolation across such cuts without
an explicit mask. The script records baseline and seed metrics before it tests
the seed against the distortion guards. Failed seeds are not accepted fits.

`continue_fit.jl STUDY_DIRECTORY TRIAL_NAME NEW_OUTPUT_DIRECTORY` continues a
valid checkpoint while retaining its original baseline. `CONTINUITY_OUTER_STEPS`
sets the step limit. Optional overrides are `CONTINUITY_STRENGTH`,
`CONTINUITY_FOLD_STRENGTH`, `CONTINUITY_BORDER_SCALE`, `CONTINUITY_SPREAD_LIMIT`, and
`CONTINUITY_PROXIMAL`. Set `CONTINUITY_FOLD_SMOOTHING` to an area in km² to
replace the sharp positive-area penalty with a Huber penalty. It is quadratic
below that area and linear above it. Zero retains the original penalty. This
changes the optimization objective, not the reported triangle areas.
The runner copies the border mask and checks its edge count against the checkpoint.

A fixed border penalty can leave a finite jump as target cells get smaller.
The internal penalty already scales with `f²`. Test a border scale of `f` to
increase the border constraint as cell width decreases. This is an experimental
scaling rule, not a guarantee of continuity or of an invertible map.

Set `CONTINUITY_COORDINATE=1` to update one country at a time. Countries with fewer
target cells go first. Each accepted update lowers the same full objective.
A blocked country does not stop updates to the others. Stop when a complete pass
accepts no updates, or at the pass limit. This is alternating optimization, not a
permanent one-way lock. `updated_country` identifies each update in the CSV.
Tests check objective decrease and mass constraints on CPU and oneAPI.

## Several neighbouring countries

`shared_borders.py BOUNDARY.geojson NEW_OUTPUT.csv COUNTRY_CODES...` lists pairs
with shared boundary segments. A common point alone does not create a border.
The regional runner intersects this list with actual OWID grid contacts. It
records missing true contacts and false artwork contacts in `graph-audit.csv`.

`regional_pose.jl SOURCE_DIRECTORY NEW_OUTPUT RESOLUTION BORDERS.csv COUNTRY_CODES...`
tests eight poses per country. It stores country costs and pairwise border costs
in small tables. A deterministic search changes one country's pose at a time,
from several starting configurations. This avoids an exhaustive search over all
pose combinations. It is not a proof of a global optimum. Tests compare the
table objective with the full transport objective and check a small exhaustive
example.

The runner compares original and selected starting poses with the same settings.
Strength scales with country count because the transport objective is a sum over
countries, while edge penalties are averages. This regional test includes all
seven neighbours of Mali. Borders outside the selected region are not constrained.
An improvement for one pair does not establish a solution for the whole planet.

## Contacts that cannot become continuous

`contact_bounds.jl REGIONAL_STUDY_DIRECTORY NEW_OUTPUT.csv` checks every artwork
contact, including contacts excluded from fitting. It finds the smallest chord
distance between any source point in each country. Every cross-seam RMS distance
must be at least this value. Population constraints can only increase the minimum.
This is not a bound on distances between mean positions: mixing distant sources
can move a mean into an empty region.

The West Africa grid has 25 country contacts. Only 15 are geographic neighbours.
It omits 13 of the region's 28 geographic neighbour pairs. At native H3-5, the
Nigeria–Senegal contact has a minimum source RMS distance of 1,609 km. Ghana–Senegal
has a minimum of 966 km. No country-preserving transport fit can make these
contacts continuous with the artwork unchanged. Keep them as explicit cuts, or
change the target layout or country membership. Do not hide them with mean-only
measurements.

## Population limits at real borders

Run `capacity_bounds.jl STUDY_DIRECTORY BORDER_CSV NEW_OUTPUT.csv FACTORS...`.
This checks the source population needed by boundary cells. It does not run a fit.

For each source point, let `d²` be its squared chord distance to the nearest source in
the other country. A target with mass `b` and `m` border edges contributes at least
`m P d² / b` to the sum of squared edge distances. Keep the source mass limits.
Assign the nearest available population to targets with the largest `m / b`.
This gives a lower bound because the other country's mass limits are omitted.
Repeated edges use the same target mass. The calculation permits the fit's 0.1%
relative target-mass error.

The percentile bound also limits how much source mass any set of edges can use.
Use `maximum_exposure = max(m / ((1 - ε) b))`, where `ε` is the relative mass tolerance.
For `r` edges, this requires at least `r / maximum_exposure` of the source mass.
The nearest available mass gives a bound on the `r`th ordered RMS value. The code
combines this with the all-edge bound and interpolates the two ranks used by the
90th percentile. Tests cover unequal target masses, repeated endpoints, and
random feasible plans.

With H3-4 sources and the original grid, Algeria–Mali has all-edge and 90th
percentile lower bounds of 793 and 520 km. Algeria–Niger has bounds of 1,022 and
972 km. Thus even these real borders cannot reach small internal distances on
this grid. At subdivision 14, the all-edge bounds fall to 256 and 278 km.
These are lower bounds, not predicted fit results. They support finer boundary
cells rather than a larger penalty alone. This bound uses the existing source
data. It does not need island population totals.

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
Geographic extents match between each pair of panels. New previews copy the
fitted seam list, so the plotter excludes false artwork contacts. Set
`CONTINUITY_LINE_PAIRS=466-854` to limit the plot to one pair. Component counts depend
on a score threshold and population coverage; fewer components alone do not
prove a better mapping. Transported population is reported as a conservation
check. Chromium runs headlessly and closes after the screenshot. No server starts.
