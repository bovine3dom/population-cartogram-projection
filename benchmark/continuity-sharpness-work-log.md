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

## 08:26 UTC: complete-pass checkpoints

Added the optional `save_passes=true` setting. It saves plans and their metric
prefix together at complete pass boundaries. This lets the timed planet trial
retain a complete pass without copying a mixed candidate during the next pass.
The default is unchanged. All 110 compact CPU checks pass, including exact
agreement between the final pass snapshot and candidate. The earlier oneAPI
checks cover the unchanged numerical path. The next global trial will use
sharp pose seeds, per-country eta, full-step trials, and a proximal weight of
0.01. It will not replace a public dataset automatically.

## 08:44 UTC: independent checkpoint audit

Added `audit_sharpness.jl`. It reconstructs full compact-plan statistics and
checks masses, source identities, populations, and the saved objective. Its
report separates source spatial spread from inverse geographic spread and
includes border errors and reversed triangle area. Input hashes detect a
checkpoint or reference change during the audit. Nine CPU checks pass,
including rejection of changed populations and incorrect objective records.
A real two-country oneAPI refit and its complete-pass audit also pass.

China passes eta 1e-5 with 4.846 connections/source at 99.5%; the next eta
is 1e-6. US and India already have sharp, checked baselines. The remaining
149-country calibration and global refit are queued in that order. The refit
will reject broad or mass-invalid seeds. Its hard stop is 17:45 UTC, leaving
time to audit the last complete pass before the overall deadline.

## 09:36 UTC: all fitted-country sharp baselines checked

China passes eta 1e-6 with 1.506 connections/source at 99.5%, target L1
7.18e-5, and maximum target relative error 0.000800. The other 149 countries
finish calibration at 09:20 UTC. The first refit attempt rejects Syria before
fitting: its nearest-budget selection has 1,865 rows against a 1,486-row
budget, just above the trial's 1.25-times limit. The next attempt uses Syria's
already checked sharper stage, with 1,092 rows. Calibration files are unchanged.
The new fit is `planet-refit-v2/`; the rejected attempt remains available.

An independent full-plan baseline audit passes for all 152 fitted countries.
These have 353,480 sources and 51,891 country target cells. At 99.5%, they need
1.906 connections/source, versus 1.837 for the same sources in production.
Mean source spatial RMS is 0.426 coordinate units, versus 0.412 before.
Mean effective support is 1.309, versus 1.325 before. Thus the new seeds reach
the earlier sharpness range without the old mass errors. The other 54 countries
are outside this fit and are not included in these matched figures.

The sharp seeds have border RMS 695.2 km and reversed triangle area 508,559 km².
Sharpness does not remove geometric defects. The border refit is now running
with per-country eta, proximal weight 0.01, and checked full-step trials. The
baseline report is `planet-baseline-audit.toml`; no public file has changed.

## 10:16 UTC: sharp-prior convergence failure and checked recovery

The first border pass stops at Russia: the factor-16 retry reaches 10,000
iterations without passing the mass check. No invalid plan is accepted.
A separate solve with the exact saved prior and force starts at factor 64,
then halves through 1. It passes all stages and the final original-temperature
mass check. The final target L1 is 7.99e-5. This trial is `retry-russia.log`.
Added an explicit power-of-two retry factor to the compact research solver
and runner. The default remains 16; saved settings record the choice. All
114 compact checks pass on CPU and oneAPI, including the longer retry path.

The stopped partial pass has 1.826 connections/source at 99.5%, versus 1.837
in the matched old export. Mean spatial RMS is 0.510, versus 0.412 before.
Border RMS falls from 695.2 to 663.6 km, but reversed triangle area increases
from 0.509 to 2.598 million km². This is not a complete pass or a publication
candidate. Its independent audit is `planet-partial-v2-audit.toml`. Resume
from this checked checkpoint rather than repeat completed country updates.

## 11:16 UTC: publication metadata checks and second difficult country

The factor-64 continuation passes Russia and the US at the requested final
eta. India still fails at the first hot stage after 10,000 iterations, with
scaled residual 10.54. The partial checkpoint remains valid; the fit has not
completed its first pass. The next continuation will start hotter, at 256,
without changing final eta or accepting an unchecked hot-stage plan.

Planet publication now uses recomputed compact moments for orientation checks
instead of generic implicit matrix multiplication. It also copies the selected
country eta table into the output. The dense and compact oneAPI publication
fixtures pass, including eta-table preservation. No real dataset is published
by this test. The full planet regression has 12 workflow checks, plus the
assembly and shared-target checks.

## 13:20 UTC: first complete sharp border pass

The factor-256 continuation passes India and China at the requested final eta.
The first whole-planet pass is complete. Its immutable snapshot and independent
audit are in `planet-refit-v4/fit/pass-1.jls` and `pass-1-audit.toml`.
The skipped update prefixes are verified in the earlier continuation roots.
The second pass is running. No mass limit was relaxed.

Matched results cover the same 353,480 fitted sources:

| Mapping | Connections/source at 99.5% | Mean source spatial RMS | Low-population connections/source |
| --- | ---: | ---: | ---: |
| Old production | 1.837 | 0.412 | 1.607 |
| Old full continuity | 147.973 | 5.868 | 102.432 |
| Old mobile continuity | 5.738 | 5.739 | 3.384 |
| New sharp baseline | 1.906 | 0.426 | 1.634 |
| New sharp border pass 1 | 2.004 | 0.715 | 1.773 |

Low population means below one tenth of a uniform country target quota; the
same 277,637 sources meet this condition in each row. Coordinate units, not
kilometres, are used for source spatial RMS. The production export already
omits tails. The first pass is close to the old connection ratio, but its
remaining long-distance contributions still increase spatial spread. Border
RMS is about 654 km and reversed area is 3.324 million km². These defects
remain important; the map is not a solved continuity result.

A research-only export of pass 1 retains 99.999%, not 99.5%, and restores all
54 unfitted countries. It has 1,107,156 rows, 387,294 sources, and all 1,715
labelled sources. The transport is 75,581,682 bytes and density is 6,197,474
bytes: 81,779,156 bytes combined, without mobile moment reduction or new
transport compression. After export, fitted-country target L1 is at most
9.57e-5 and maximum relative error is 0.0009862; source sums pass as well.
Files are under `preview-pass-1/`, not H3-MON. No public file has changed.

## 14:30 UTC: direct mobile packing without moment reduction

An independent Arrow check confirms source coverage, UInt32 H3 halves, positive
density values, city names, and physical target weights. It also finds that
raw sparse row counts would change the displayed country owner of four shared
Lesotho cells. This is a row-count rule in the consumer, not a mass change.

Added `mobile/pack_mapping.jl` for an already sparse fitted mapping. It reuses
the existing mobile writer, with no moment solver. It keeps the original
shared-cell owners by splitting existing rows and then checks the actual Arrow
output against the supplied sparse fit. Eight tests pass, including a changed
shared-cell owner, city anchors, output overwrite rejection, and bad density.

The first-pass packed preview is 28,322,066 bytes for transport and 5,035,946
bytes for density: 33,358,012 bytes combined. It has 1,104,099 rows. Packing
adds 52 ownership rows and removes 3,109 unlabelled roundoff tails below the
existing 1e-20 thresholds. Maximum target total variation from the new sparse
fit is 2.62e-8. Maximum target mass relative change is 5.94e-8, and geographic
mean movement is 1.32e-5 km. All 1,715 city anchors remain. These are packing
checks, not claims about continuity quality. Files are `packed-pass-1-v2/`.
No gzip or application compression was added; production zstd is unchanged.

## 14:32 UTC: headless browser check

The packed first-pass files pass the isolated H3-MON browser check with a
390-by-844 viewport, four-times CPU throttling, and three viewport cycles.
All 387,294 source values and 54,931 physical target cells load. The browser
shows 1,714 target labels from 1,715 labelled sources. There are no page errors;
the existing legend-transform warning remains. H3-MON itself stays stopped.
The first attempt found no Playwright-managed browser; the repeat uses the
installed `/usr/bin/chromium` with software rendering.

Load time is 20.1 seconds in this local test. A 128 MiB V8 heap limit passes,
but this is not a 128 MiB total-memory result: after collection, reported heap
use is 39.6 MB and backing storage is 120.1 MB, before other browser costs.
This is a headless desktop check, not a real mobile-device test. The screenshot
and memory trace are in `browser-pass-1-128-system/`. No app files were changed.
