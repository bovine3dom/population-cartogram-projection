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


## 09:16 UTC — Fold size and native-resolution validation

The revised coarse study completed. Cost conditioning reduced the first no-fold
case from 866 to 145 seconds with the stated tolerance change. All 68 GPU checks
passed before launch. Native H3-5 validation is now running.

Triangle counts alone concealed useful information. At border share 0.25, the
unpenalized candidate has 84 positive triangles with total positive area
356,410 km². Fold strength 0.1 leaves 49 positive triangles but reduces that area
to 8,157 km². Its border median is 209 km, versus 553 km at baseline and 161 km
for current nearby internal edges. This is progress, not a fold-free result.
The smaller penalty gives a lower median but larger remaining folds.

Added positive-area totals and maxima to the diagnostic, with two tests.
The full line preview for share 0.1 and fold strength 0.01 is at
`output/continuity/preview-fold4/lines.png`. Some gaps remain, especially along
Angola–Zambia. Native-resolution and subdivision tests are needed before selecting
an approach. Added case and step filters to keep larger tests within the time
budget. No production settings were changed.


## 10:48 UTC — Native results and a proximal check

The H3-5/factor-1 study completed. It confirms the coarse result: DRC–Angola and
DRC–Zambia can improve substantially, but Angola–Zambia remains difficult.
For border share 0.25 without a fold penalty, its median remains 420 km, versus
239 km for nearby internal edges. The combined regional median hides this case.
The H3-5/factor-3 baseline completed and its outer fit is running.

Added a KL-proximal variant to test smaller transport changes. All 71 checks pass,
including oneAPI checks and the proximal fixed-point test. Paused the factor-3
process for about seven minutes to give this coarse test sole GPU use, then
resumed it. Do not compare its wall time with uninterrupted runs without that
qualification.

All four proximal cases completed. Proximal weight 0.01 with fold weight 0.1 gives
border median 157 km, local median 176 km, and positive area 9,102 km². Proximal
weight 0.1 reduces positive area further, to 1,225 km², but its border median is
249 km. This is a trade-off, not a complete solution. Reports are in
`benchmark/continuity-runs/africa-proximal4.csv`. The experiment does not change
the population constraints, and the core solver remains unchanged.


## 12:16 UTC — Refined solver limits and next tests

Stopped the original queue at 11:20 UTC. The factor-3 fit failed its first sharp
inner solve; its complete baseline is saved. The H3-6/factor-2 baseline is also
saved, but its first inner solve was still running. Neither is an accepted fit.
Mali–Burkina Faso remains a difficult holdout: the best initial setting reaches
a border median of 454 km from 853 km, then stops near its internal-maximum guard.
Other settings stop much earlier. Germany–Poland completed separately.

Entropy continuation reduces the Angola factor-3 inner residual from about
0.044 to 0.00025, but this still fails the final test. Anderson acceleration alone
does not remove that limit. A longer final primal refinement succeeds: 6,900
primal steps reach 0.0000999. The complete Angola solve takes 258 seconds. DRC is
still running. These checks show that the larger costs need more than a relaxed
iteration count. No failed candidate has been exported as a valid mapping.

Next, test the proximal method on the saved refined baseline. Its larger inner
entropy permits smaller transport changes while the outer objective retains the
requested entropy. Also separate internal mean smoothness from source spread:
the original distribution penalty increases both when multiplied by subdivision
factor squared. The border penalty will still include spread. All 73 CPU checks
pass after this option; the preceding solver changes passed 75 GPU checks before
these three new checks. Outputs and limits remain separate from production.


## 13:18 UTC — A useful Mali result and an initialization check

Mali–Burkina Faso now has a substantially better result. A 270-degree starting
pose for each country, followed by strength-10 fitting, reduces the border
median from 853 to 78 km. The current local internal median is 84 km. Border
RMS distance is 92 km versus 104 km locally. Mean source spread decreases to
39 km. One positive triangle remains, with area 1.74 km². The largest internal
jump is 354 km, versus 182 km at baseline. Thus internal distances do increase,
but the result is not made by broad source mixing or large folds.

The same straight-line previews are at
`output/continuity/preview-mali-pose5/lines.png`. The selected high-jump line has
one geographic footprint component after fitting, versus two before. The other
line retains a gap in a sparsely populated region. Source population is conserved
to the sparse export tolerance. Red centre traces alone are not used as proof.

An ablation with the same strength and the original starting pose stops at
563 km, with much larger folds. The starting pose matters in this case; simply
increasing strength is insufficient. Rotations only make starting assignments.
The artwork and true source coordinates do not change. Refinement uses the
original cost, not a rotated replacement objective.

The unseeded H3-5/factor-3 mean-internal fit completed at 249 km border median
versus 40 km local median. Subdivision alone is not sufficient. Its distribution
variant is running. Native Africa pose search completed 512 combinations. The
best coarse candidate rotates Angola by 45 degrees and leaves DRC and Zambia
unchanged. A 15-minute native refinement pilot completed 91 steps of the original
pose comparison before its timeout; checkpoints remain valid. Further selected
pose tests will use smaller step limits. The fine job was paused during small
GPU pilots and then resumed, so its wall time includes those pauses.


## 14:20 UTC — Fine-grid validation and a wider regional check

The Mali H3-5/factor-3 fit completed. Its border median is 50.5 km, versus 878.6 km
at the matched baseline. The nearby internal median is 24.3 km. Border and local
90th percentiles are 70.8 and 64.3 km. Border RMS distance is 57.8 km, versus
38.6 km locally. Mean source spread decreases from 19.8 to 18.6 km. Total positive
triangle area is 130 km², versus 318 km² at baseline. The internal maximum grows
from 361 to 540 km. This is a substantial improvement, not an exact continuous map.

The first interpolation used separate local linear fields. Their joins created
folds before transport started. Replaced these with continuous affine fields on
the coarse triangles. Edge extrapolation still needs checks. The first runner
also exposed a parse error after saving its seed. Added syntax tests for all
Julia research scripts. Corrected the orientation of the new test fixture.
All current CPU tests and the shared-border Python test pass.

A fixed border weight becomes relatively weaker as internal penalties scale with
subdivision. A continuation now tests border weight multiplied by factor 3.
It retains the original matched baseline and strict mass tests.

Prepared 15 West African countries, including all seven neighbours of Mali.
Natural Earth supplies 28 shared-segment pairs. The next test will constrain only
pairs that also touch in the artwork. A country-pose graph tests many starting
configurations without enumerating all combinations. Its objective has tests
against the full transport objective. This check is necessary: a good pair fit
can make other borders worse.

Process note: stopping the queue parent at 13:43 UTC did not stop one nested
stage timeout. That stage had its own process group. It continued beside the
native Africa pose test until 14:08 UTC, when its group was stopped directly.
Its last complete checkpoint has 68 steps. Those overlapping wall times are not
benchmark results. The new queue uses foreground stage timeouts and a shared
process group. Each stage also has a remaining-time limit. All jobs stop before
18:55 UTC, which leaves time for final checks before the exclusive window ends.
