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
