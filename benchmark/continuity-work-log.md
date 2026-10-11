# Cross-border continuity work log

## Time window and rules

Start: 2026-10-11 07:01 UTC. Deadline: 2026-10-11 19:01 UTC.

Keep the OWID geometry fixed. Keep country population constraints. Use
KernelAbstractions and oneAPI for transport solves. Do not replace production
H3-MON files. Do not commit unrelated France files or other user work.

The aim is to make genuine cross-border discrepancies comparable to nearby
internal discrepancies. A lower global objective is not sufficient. Check each
border, local internal edges, source spread, and full source distributions.
Record unsuccessful trials and infeasible cases as well as improvements.

## 07:03 UTC — Initial state

The existing coarse experiment is uncommitted. It uses a saturating penalty on
geographic target means, with Sinkhorn as the inner solver. The core package is
unchanged. The Africa trial gives Angola–DRC median separation of 560 km versus
881 km at baseline, but internal jumps are much smaller. This is not yet enough.

There are 55 international edges and 2,007 internal edges in the three-country
Africa case. Explicit border weighting is necessary. The current spread and
internal-distortion guards limit all changes to 5% above baseline. These guards
may also prevent useful redistribution, so their effects must be measured.

A previous Russia source extraction has used one CPU core for more than
40 minutes without reaching its fit. Stop that job and use the existing global
population mapping for matched baseline/candidate trials. Its completed Germany
and Indonesia outputs remain available. No result files will be removed.

Planned stages:

1. Commit the current tested experiment and audit as a reproducible starting point.
2. Add local border metrics and source-distribution checks, with checkpointed plans.
3. Test stronger mean penalties and penalties that also account for spread.
4. Compare outcomes with nearby internal edges and inspect full line footprints.
5. Validate useful settings on other African borders and at higher H3 resolution.
6. Record limits, tests, and the best supported result before the deadline.

## 07:08 UTC — Distribution checks and a stronger sweep

Committed the starting point as `fdb0d70`. Stopped the unproductive Russia
extraction. Added local border comparisons, full-plan checkpoints, and an
expected source-to-source squared-distance penalty. The latter accounts for
spread instead of considering target means alone. Both penalty forms have
finite-difference derivative tests, including changes to target mass.

All 37 experimental checks pass, including oneAPI/CPU agreement. The first
12-setting sweep is running on oneAPI with a hard timeout at the window's end.
Outputs: `output/continuity/africa-sweep-1/`.

Early observation: stronger border forces improve the seam but increase jumps
immediately inside it. Global internal percentiles hide part of this effect.
Both baseline-local and candidate-local statistics must therefore be retained.
The first distribution/quadratic setting reaches its 25% internal-maximum guard
before the border median becomes comparable to the local internal median.

## 07:19 UTC — Capacity limits and internal smoothing

The first 12-setting sweep completed. Distribution penalties perform better
than mean-only penalties when source spread is checked. For example, strength 1
with the uncapped distribution penalty reduces the regional seam median from
553 to 255 km. However, nearby internal median distance increases from 69 to
148 km. This is not a clean success.

A second sweep now gives internal edges more weight. It also tests preservation
of the baseline internal displacement field. The internal-maximum limit is
relaxed to twice baseline for diagnosis, not as a production acceptance rule.
Outputs: `output/continuity/africa-sweep-2/`.

Added an optimistic population-capacity bound. Angola must assign 4.71% of its
population to the 12 distinct target cells along its Zambia seam. Even selecting
the closest available Angolan population, and ignoring Zambia's capacity and
all layout constraints, gives mean nearest-source separation of 250 km at H3-4.
The corresponding supply radius is 417 km. This bounds mean physical source
separation, not target-centre distance. It also does not directly bound a median.
Native H3-5 inputs are prepared to check the effect of coarse aggregation.

Added orientation diagnostics. A strong first-sweep candidate creates 54
positive-area triangles where the baseline has none. Small edge distances alone
do not establish a valid continuous map. This requires further attention.

Corrected experimental sparse exports for parent H3 cells shared by countries:
source-normalized weights now account for each country's fraction of the parent
population. Otherwise a line score could be counted twice. Full-plan optimisation
is unchanged. All 50 CPU checks pass; GPU agreement was checked in the preceding
stage. No production exports were changed.

## 07:59 UTC — Subdivision, folds, and solver precision

The native H3-5 data confirms the Angola–Zambia supply bound: 251 km on Angola's
side. Subdivision changes this constraint without changing the artwork. The
bound falls to 174 km at factor 2, 138 km at factor 3, and 99 km at factor 5.
The number of cells along the seam grows more slowly than the total cell count,
so the seam requires a smaller fraction of country population. This is a useful
route to test, not a guarantee of continuity.

The balanced coarse sweep completed. Strong distribution penalties can make the
regional seam median smaller than the nearby internal median. However, the local
internal median has increased, some country pairs still have large gaps, and
orientation checks expose folds. The full before/after line plots at
`output/continuity/preview-balanced4/lines.png` show these trade-offs. They use
H3-MON's actual stroke projection. Transported population is nearly unchanged.

Added a soft positive-area penalty and derivative tests. Added a matrix-free GPU
cost representation for the geographic forces, while retaining full host plans
for objective checks. Target/source-only cost constants are removed to improve
conditioning. Warm starts preserve dual cost offsets.

The first matrix-free fold study failed its strict marginal test at residuals
of roughly 0.00002–0.00004. Failed outputs are retained. Added a short primal
matrix-scaling refinement on KA/oneAPI to correct this Float32 dual precision
limit. It runs only near a balanced solution. It does not use a CPU solver or
relax the marginal criteria. All 65 experimental checks pass, including GPU
agreement, force gradients, orientation gradients, and marginal refinement.

Next: repeat the fold study, then validate at native H3-5 and subdivided targets.
The core package and production H3-MON files remain unchanged.

## 08:30 UTC — Bounded validation queue

Started a deadline-bounded queue for fold tests, native H3-5 fits at factors 1,
3, and 5, Mali–Burkina Faso and Germany–Poland holdouts, and a Kontur H3-6/factor-2
check. The three H3-6 country extracts finished successfully in the background.
The queue writes small case reports and commits only those report paths. Large
plans remain ignored. Candidate checkpoints now use an atomic rename, so an
interrupted write does not replace the previous complete plan.

The strict fold rerun is producing balanced candidates but spends too much time
near the Float32 precision limit. Added row and column cost offsets to the
matrix-free path. These leave the constrained optimum unchanged. A real Angola
inner solve then converged in 1,250 dual iterations, without primal refinement,
at target L1 error 0.00000974.

For subsequent native-resolution studies, use target L1 tolerance 0.0001 instead
of 0.00001. Keep the maximum relative target error limit at 0.001 and keep exact
source normalization. This is an explicit numerical-budget change, not a
relaxation of country membership or target geometry. Baseline and candidate use
the same tolerance, and both achieved errors are recorded. It limits average
absolute target error to 0.01% and each target's relative error to 0.1%.
