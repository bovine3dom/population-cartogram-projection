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
