# Continuity sharpness work log

## Window and scope

Start: 2026-10-14 06:50 UTC. Stop: 2026-10-14 18:50 UTC.

Find the earlier sharp-mapping method in commit history. Compare source-to-target
support before and after border fitting. Aim for the earlier support ratio,
while retaining mass checks and measuring border quality. Do not replace the
published planet, production, UK, or Germany data during the investigation.
Keep H3-MON stopped. Leave unrelated research jobs and files unchanged.

Use KernelAbstractions and oneAPI for fitting trials. Keep large results under
`output/continuity-sharpness/`. Use bounded trials and record failures. Raw row
count alone is not a sharpness measure: also measure support at equal retained
mass, effective support, and spatial spread. Compare matched resolutions and
country inputs before drawing conclusions.

## 06:55 UTC: first history findings

Commit `6be9396` ports the automatic eta tuner to KernelAbstractions. The current
`src/automatic_eta.jl` still contains it. It searches decreasing eta values and
counts the connections needed to retain 99.5% of each source distribution.
Its target is twice the sum of source and target counts, per country. It keeps
the converged candidate nearest this row-count target. This is not a constant
number of connections per H3 cell.

The planet continuity runner does not call this tuner. Its baselines, poses,
and outer fit use a fixed eta of 0.002. Its export retains 99.999%, rather than
the production tuner's 99.5%. Both differences can increase row counts. The
outer proximal weight and damped plan history also need review. A proximal
weight must not be confused with permanent entropy: its effect depends on the
prior plan and the number of completed updates.

Earlier commits to inspect include `22ca9ca`, `07108f5`, `32e42a6`, `12745e0`,
`cc2dfdd`, and `82585bc`. No claim of a sharpness fix is made yet. The compact
mobile export changes weights while preserving selected averages; it is not
evidence that the fitted source distributions are sufficiently concentrated.

## 07:06 UTC: matched export audit and strict eta trials

The original tuning change is `cc2dfdd`: it adds automatic eta selection.
Commit `12745e0` then changes the row multiplier from 10 to 2 and extends eta
candidates down to 1e-7. It also relaxes the old marginal tolerance to 0.02.
The current continuity checks are much stricter: target L1 at most 1e-4 and
maximum target relative error at most 0.001. Do not relax those checks merely
to reproduce an old row count.

Added source-distribution diagnostics and 29 checks. They combine duplicate
physical target positions, normalize each available source distribution, and
measure support at 99.5% and 99.999%, inverse-Simpson effective support,
entropy support, and spatial RMS spread. Spatial units are target coordinates,
not kilometres. All three exports have the same 387,294 source IDs and 54,942
country target cells. Production already omits tails, so its normalized 99.5%
count is not a reconstruction of the original unpruned production plan.

| Export | Stored distinct connections/source | Connections/source at 99.5% | Mean effective support | Mean spatial RMS |
| --- | ---: | ---: | ---: | ---: |
| Production | 2.310 | 1.875 | 1.337 | 0.425 |
| Full continuity | 311.787 | 135.251 | 4.691 | 5.404 |
| Mobile continuity | 6.178 | 5.411 | 3.051 | 5.285 |

The mobile exporter removed many connections but barely reduced spatial
spread. Low-population sources show the same problem. Among the same 307,595
sources with population below one tenth of a uniform target quota, the mean
99.5% support is 1.656, 92.661, and 3.232 respectively. Mobile ownership guard
rows merge at the same position; this explains 22 fewer distinct connections
than file rows. Full CSVs are in `output/continuity-sharpness/export-audit/`.

Seven oneAPI country sweeps pass the strict mass checks at much smaller eta.
For example, DRC at eta 0.002 needs 58.24 connections/source at 99.5%; at
5e-5 it needs 2.257. This is a no-border baseline, not yet a border-fit result.
The diagnostic runner then stopped because code 250 is absent from the
saved fitted-country set. The seven completed countries and their stage
checkpoints remain valid. See `tuned-small-v1/` and its log.

Another source of persistent tails is the outer step rule. It tests damping
at 0.5 or smaller, never 1. After four accepted updates, at least 6.25% of the
initial plan remains through explicit mixtures, even if proposals are sharp.
The proximal prior can preserve more. This makes a sharp initial plan and a
checked full-step trial important. It does not justify removing mass checks,
objective descent, or spatial distortion checks.

## 07:10 UTC: optional full outer steps

Added `max_damping` to the research runner. The default remains 0.5, so old
runs keep their step sequence. The optional value 1 tests a full step first;
all acceptance checks remain. Dense and compact full-step comparisons pass.
All 86 compact checks pass on CPU and oneAPI. The saved settings retain the
new value. This is a controlled trial option, not a claim of better border
quality. The next tests compare sharp and broad initial plans with both step
limits and two proximal weights.

## 07:40 UTC: small border trials and reusable eta tuning

Four Mali–Burkina Faso trials use the saved planet pose angles and the same
border weights. All use strict mass checks, the existing spread and interior
limits, and 20 passes. These are factor-1 regional trials, not planet results.

| Eta | Proximal | Maximum step | 99.5% connections/source | Border RMS, km | Reversed area, km² |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0.002 | 0.1 | 0.5 | 6.259 | 125.8 | 423 |
| 0.0001 | 0.1 | 0.5 | 1.487 | 171.4 | 2,467 |
| 0.0001 | 0.1 | 1 | 1.332 | 164.2 | 1,218 |
| 0.0001 | 0.01 | 1 | 1.885 | 123.5 | 5,206 |

Lower eta can retain a sharp mapping during border fitting. But these tests
also show a geometric tradeoff: fewer connections do not guarantee fewer
folds. The lower-proximal trial improves border RMS while its source spatial
spread increases and its reversed area remains high. Do not publish it as a
solved map. Logs and stage audits are in `mali-*-v2/`. The first script attempt
stopped on a Julia global-scope error before outer fitting; its seed checks
remain saved as `mali-sharp-full-v1/`.

Added `compact_tune` for checked baseline eta selection, plus per-country eta
values in `run_case`. Each country uses the same selected eta in its solve and
objective. The values are saved in `country-etas.csv`, loaded on restart, and
scaled by grid refinement. The scalar-eta path is unchanged. The tuner reports
its stage outcomes and whether its selected plan meets the row target; it does
not label a failed sharp stage as a success. All 105 compact checks pass on CPU
and oneAPI, and all 34 source-diagnostic checks pass. The large-country process
was paused during the oneAPI regression run, then resumed.

The US, India, and China baseline sweep started at 07:25 UTC with a two-hour
process limit and a 2 GiB device cache limit. Its files are `tuned-large-v1/`.
At 07:35, the US passes at eta 1e-5 with 4.04 connections/source at 99.5%; the
next stage is still running. No whole-planet sharpness result exists yet.

The old production file is not an exact mass-feasible reference. An independent
audit finds source sums and target populations outside the new strict limits.
For example, US source sums range from 0.954 to 1.073. China's maximum target
relative deviation from a uniform quota is 96.69. The old 0.02 aggregate mass
tolerance could conceal large individual errors. Keep the new strict checks;
use old support counts as a sharpness goal, not as permission to copy these
mass errors. See `production-mass.csv` for the full audit.

## 07:50 UTC: US baseline reaches the old sharpness range

The US passes at eta 1e-6. Its 99.5% support is 1.297 connections/source,
versus 1.272 in the old exported mapping. Mean inverse-Simpson support is
1.112, versus 1.110 before. Mean source spatial RMS is 0.181 coordinate units,
versus 0.169 before. Target L1 is 7.99e-5 and maximum target relative error
is 0.000341. This is a sharp, mass-checked baseline, not yet a border fit.
The large-country sweep is now on India. Stage times include two deliberate
pauses for small oneAPI checks; they are not performance benchmarks.

Added `tune_baselines.jl` for resumable country calibration. It saves stages,
selected plans, code/input hashes, and a table of achieved support. It rejects
changed configurations and unknown country codes. A two-country oneAPI run,
its completed-country restart, and rejection checks pass. The next calibration
will cover the other 149 fitted countries after the large-country GPU job.
The selected pose angles remain the earlier checked angles; this work does
not claim to find new globally optimal orientations.

## 08:22 UTC: baseline progress and retained broad mixtures

India passes at eta 1e-6 with 2.005 connections/source at 99.5%, versus 1.931
in the old export. Target L1 is 7.99e-5 and maximum target relative error is
0.000228. China is still running. The queued 149-country calibration will not
start while the large-country GPU process is active. Its own process limit
is four hours. All jobs must finish before the overall 18:50 UTC deadline.

The saved four-pass planet plans explicitly retain 30.76% of China's broad
pose seed, 19.14% for the US, and 9.375% for India. The minimum and median seed
weights across nontrivial fitted countries are both 6.25%. This confirms that
short, damped runs preserve broad tails; this is not only an Arrow threshold
problem. The old candidate has border RMS 613.45 km and about 8.02 million km²
of reversed triangle area, versus 60,126 km² in its pose seed. These are cached
moment diagnostics, not a new independent full-plan reconstruction.

Added a cached-moment callback to the orientation audit. It copies the supplied
moments before normalization and avoids expensive generic multiplication of a
compact plan. Existing continuity tests and two cache-equivalence/immutability
checks pass on CPU. See `old-plan-metrics.csv` and `old-candidate-history.csv`.

A separate CPU diagnostic removes the mobile export's source-position moment
constraints, but keeps source mass, target mass, geographic target means, mean
density, and city anchors. Without the 70% contribution floors, Mali reduces to
1.218 connections/source at 99.5%, and Burkina Faso to 1.597. This shows that
preserving the border objective's target moments does not itself require all
of the old source connections. However, a source mean can move by up to 19.18
coordinate units, and target total variation reaches 0.827. These candidates
do not retain the published mobile quality guarantee and are not published.
The DRC full-block trial returns a nonoptimal solver status and is rejected.
Logs and valid small-country snapshots are `inverse-only*`. Eta tuning and
border refitting remain the main approach.
