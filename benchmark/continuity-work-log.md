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
