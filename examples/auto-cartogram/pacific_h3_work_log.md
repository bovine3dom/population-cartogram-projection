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
