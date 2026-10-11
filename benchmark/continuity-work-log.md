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
