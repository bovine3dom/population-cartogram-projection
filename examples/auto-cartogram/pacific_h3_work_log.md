# H3-5 population fit for the Pacific coast layout

## 2026-10-16: run setup

The user selected `coarse90-pacific-shield-v2` for the next H3-MON export.
Use its fixed 55,000 land tiles. Do not change the layout during transport.
The user requested no border-aware pass for this run.

Fit each recorded island or exclave group separately. Keep component/H3
fragments separate until export. Small components without a tile retain the
explicit assignment in `groups.csv`. Do not pool whole countries. City points
must match a source component before their labels are placed.

Use the existing H3-5 population sources and city/area cache. The fit checks
component populations against the new run's groups. Balance each group to a
maximum relative tile-population error of 0.0001. Export density as parent
population divided by actual H3 area. Keep lake cells empty.

The new runner copies the selected layout and records input and script hashes.
It stops on a failed command. It writes its phase and final process exit code.
It exports only after all group balance checks pass. The browser step captures
H3-MON in headless Chromium. These captures still require visual review.

```sh
bash examples/auto-cartogram/run_layout_h3.sh \
  output/auto-cartogram/coarse90-pacific-shield-v2 \
  output/auto-cartogram/pacific-55000-h3-5-v1 \
  planet-auto-55000-h3-5-pacific-v1 \
  /home/olie/projects/H3-MON
```

The previous layout and H3-MON exports remain unchanged. No Arrow export or
visual approval is claimed at setup. Shell syntax checks, two export tests,
and six transport tests pass.

## 20:58 UTC: fit started

The oneAPI fit is running. India is the first group: 12,595 source fragments
and 9,838 target tiles. Runner PID: 2849301. Julia PID: 2849310.
Log: `output/auto-cartogram/pacific-h3-logs/run-v1.log`.
The runner will balance, export, and capture browser images after the fit.
No border-aware stage was queued at this point. The Arrow files were not ready.

## 2026-10-17: border pass setup

The user has now requested a border-aware pass. The independent fit completed
on October 16 at 21:37 UTC with exit code zero. Its browser check reported no
page errors or failed requests. Keep that export available for comparison.

Prepared `pacific-55000-h3-5-v1/border` from the completed new baseline.
There are 186 active groups and 283 eligible border pairs. A pair must be
both a source component border and a shared tile edge. False layout contacts
do not receive border forces. The other 295 groups keep the new baseline
mapping. No population crosses a group boundary. The tile layout stays fixed.

Use one pass with the existing settings: proximal weight 0.01 and retry factor
256. Tune a sharp baseline first. Then fit, extract, balance, and audit the
exported mapping. Stop if a solve or numerical gate fails. The earlier layout
needed separate recovery for China and India; this run can also need recovery.
Do not reuse its old checkpoints with the new layout.

The new dataset name is `planet-auto-55000-h3-5-pacific-v1-border`.
`BORDER_DATASET` selects a separate destination in `run_border_h3.sh`.
The runner rejects an existing destination and records its exit code.
Shell syntax checks and all 17 component-border tests pass.

Started at 07:42 UTC. Runner PID: 2856035. Log:
`output/auto-cartogram/pacific-h3-logs/border-run-v1.log`.
The separate border-aware Arrow export is not ready yet.
