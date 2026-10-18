# Borneo: scale the whole island first

[Review the comparison](http://proto.olie.science:8642/results/owid-borneo-outline/index.html).

## Method

The previous trial scaled each country part separately. It kept country counts
and contacts, but did not protect the combined island outline. Brunei also
remained anchored near its old position.

This trial combines the original OWID parts of Borneo into one outline. It
scales that outline uniformly, then converts it to exactly 166 connected tiles.
The old area was 286 tiles. The linear scale factor is approximately 0.762.
Grid rounding changes small details.

The solver must fill exactly this outline. It assigns 44 tiles to Malaysia,
118 to Indonesia, and 4 to Brunei. Each part uses the same geometric transform
as its position guide. Connectivity roots move inside the new outline.
Country parts must remain connected and retain their existing contacts.

Only these three parts change from `owid-island-motion-v2`. The peninsula,
Philippine islands, country totals, and population assignments remain unchanged.
The final checks also compare all land contacts and enclosed water with that
parent layout. The old border-fit records in `report.json` describe the parent
stage; `landmass_fit` describes this new stage.

## Work log: 2026-10-18 UTC

- Added an optional fixed land outline to the local fit solver. Existing calls
  keep their previous behaviour.
- Ran the shared-island fit with a 180-second limit. The solver reached an
  optimal solution for the local objective.
- Visually compared original OWID, separate-country resizing, and whole-island
  resizing. The new outline retains the island's principal shape. Brunei is
  within the coastal outline rather than on a projection.
- The Malaysian strip remains narrow. That follows from the new count and the
  fixed outer outline. This trial does not claim exact geographic borders.
- All 374 Python tests passed. New tests check exact outline occupancy, moving
  connectivity roots, and rejection of an incompatible area budget.
- Published the layout, fit record, and comparison images. The default map and
  H3-MON exports remain unchanged.

## Repeat

Run from the repository root. Use a new output directory.

```sh
PY=output/auto-cartogram/geometry-env/bin/python
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 "$PY" \
  examples/auto-cartogram/fit_owid_landmass.py \
  output/auto-cartogram/owid-island-resize-v9 \
  output/auto-cartogram/owid-island-motion-v2 \
  output/auto-cartogram/owid-borneo-outline-repeat \
  --labels MYS:T1 IDN:T3 BRN:T1 --seconds 180
```

The reference supplies the old combined outline. The parent supplies the new
counts and all unchanged parts. The export uses `data/cartogram.csv` for its
coordinate origin. Automatic source identities remain provisional.
