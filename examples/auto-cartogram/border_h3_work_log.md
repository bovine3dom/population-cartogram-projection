# Border-aware H3-5 mapping on the automatic layout

## 2026-10-15: rebase and run setup

Rebased `cartogram-auto` onto `tidying_up` at `e0be40f`. All 180 local commits
replayed without conflicts. The previous branch tip is retained as
`backup/cartogram-auto-before-border-rebase` at `f6934c1`. No remote branch was
changed. The two user PDF files remain untracked.

Use the same fixed-coast 55,000-tile layout, component/H3 fragments, populations,
and city source as the earlier island export. Keep the earlier H3-MON dataset
unchanged. The new dataset name is `planet-auto-55000-h3-5-islands-border`.

The adapter uses the branch's compact baseline tuner and `refit_tuned.jl`.
Use one border pass, proximal weight 0.01, maximum step 1, and retry factor 256.
The earlier branch study preferred one pass for sharpness. More passes reduced
border error but increased source spread. See
`../../benchmark/continuity-sharpness.md`.

Each solver unit is an island group, not a country. Keep compound component/H3
source IDs throughout the fit. A shared H3 parent does not merge island
populations. The base cost uses the earlier population-weighted projected
source coordinates. The continuity moments use H3-5 parent centres on the unit
sphere. Thus sub-cell coastal positions remain limited by H3-5 resolution.

Only exact represented-component pairs in `geographic-contacts.csv` are eligible
for border forces. They must also have side-adjacent tiles in the selected
layout. Do not remap a small overseas component's border to its assigned
mainland group. Do not add layout cells to recover a missing border.

Preparation finds **182 active groups and 289 eligible border pairs**.
The other 299 groups retain their earlier checked mappings. This includes
islands with no eligible land-border contact. Calibration started at about
00:10 UTC on oneAPI. The complete border-aware dataset is not yet available.

## Pipeline and checks

1. Tune a sharp, unforced compact baseline for each active group. Save each
   checked temperature stage and the selected result.
2. Calculate local border weights from the baseline. Keep the branch's
   distribution penalty, fold penalty, and distortion limits.
3. Run one complete border pass. Every accepted update must pass the existing
   mass and objective checks. Save the complete-pass checkpoint.
4. Extract 99.99999% of each source row, then normalize its weights. Keep source
   fragments separate. Copy unchanged groups from the earlier checked mapping.
5. Balance each sparse group to a maximum relative tile error of 0.0001.
6. Audit the actual balanced export, not only the full compact plan. Compare
   border RMS, internal jumps, geographic spread, and reversed triangle area
   against the original map and the calibrated baseline. Publication requires
   lower border RMS than the calibrated baseline and the recorded distortion
   limits. These checks are not visual approval.
7. Export density and city labels with the existing island-aware exporter.
   Capture the real H3-MON app in headless Chromium. Review the images before
   calling the result visually accepted.

Calibration and fitting each have a 12-hour process limit. A failed solve or
quality gate stops the pipeline. No failed proposal replaces an existing map.
An incomplete fit directory requires inspection before a restart.

Output: `output/auto-cartogram/world-55000-h3-5-border/`.
Logs: `output/auto-cartogram/border-run-logs/`.

## Commands

Run from this worktree. The main checkout provides the installed oneAPI
environment. The continuity scripts come from this rebased worktree.

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
OPENBLAS_NUM_THREADS=2 julia --threads=2 \
  --project=/home/olie/projects/population-cartogram-projection/examples/uk-h3 \
  examples/auto-cartogram/border_h3_groups.jl prepare \
  output/auto-cartogram/world-55000-h3-5-density \
  output/auto-cartogram/world-55000-dissolved-input/geographic-contacts.csv \
  output/auto-cartogram/world-55000-h3-5-border

bash examples/auto-cartogram/run_border_h3.sh \
  output/auto-cartogram/world-55000-h3-5-density \
  output/auto-cartogram/world-55000-h3-5-border \
  /home/olie/projects/H3-MON
```

Do not start a second tuner while the first is active. The current pipeline
waits for the separate calibration process to finish, then runs the remaining
steps. It does not restart a failed calibration automatically.

## Tests

`test/auto_border_groups.jl`: 16 checks pass. They cover exact component
contact selection, false artwork contacts, an unrepresented island, a shared
H3 parent with separate fragment IDs, two-unit tile spacing, source-normalized
extraction, unchanged groups, output guards, and rejection when border RMS does
not improve. The upstream tuned-refit test passes all 12 checks. The two Python
export tests and six transport tests also pass.

At 00:19 UTC, calibration has completed 174 of 182 active groups. The remaining
groups contain most of the target tiles. The queued pipeline has not started
the border pass yet.

## 01:38 UTC: long-running calibration checkpoint

180 of 182 active groups have completed calibration. China and India remain.
China passes the strict mass checks through eta 0.00001. The sharper 0.000005
stage needs the solver's checked temperature continuation and is still running.
Do not use the incomplete calibration as a border-aware result.

The calibration process is 2753437, with Julia child 2753438. The queued pipeline
process is 2753554. Both were checked as active. Logs are `tune.log` and
`pipeline.log` in the log directory above. The pipeline starts only after the
calibration completion marker exists. It then fits, extracts, balances, audits,
exports, and captures browser images. It stops on a failed gate.

No new border-aware Arrow files have been published at this checkpoint.
Visual review remains pending. The earlier island dataset remains available.
Implementation commit: `0e08558`.
