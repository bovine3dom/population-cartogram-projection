# Shared-footprint experiment

This is a research pipeline, not a production exporter. A completed run can
still have wrong borders, split components, poor positions, or poor shapes.
Inspect the world image, regional images, and recorded checks.

## Inputs

Use prepared component inputs and exact-count source-shaped templates. See
[the shape experiment](shape-first.md) for the earlier preparation work.
Keep geographic components separate. Do not join overseas parts by country ID.

The optional continuous-flow executable is built by `bootstrap_flow.sh`.
It uses the pinned `cartogram-cpp` revision recorded by that script. Its licence
is AGPL-3.0. It remains outside production dependencies. You can instead supply
an existing continuous geometry with `--flow-geometry FILE`.

## Run

From the repository root, with the prepared 55,000-tile files:

```sh
p=output/auto-cartogram
"$p/geometry-env/bin/python" examples/auto-cartogram/run_compact_pipeline.py \
  "$p/world-55000-dissolved-input" \
  "$p/world-55000-shape-islands" \
  "$p/world-dissolved/polygons.geojson" \
  "$p/world-55000-shared-footprint" \
  --flow-binary "$p/vendor/cartogram-cpp/build/Release/cartogram" \
  --stretch 1.5
```

Use a new output directory for each run. Run from a fixed checkout or a saved
copy of all experiment Python files. Do not edit that code while a run is active.
The pipeline records code hashes but does not lock source files.

The default smoothing scale is four
cells at 55,000 tiles. It changes with the square root of the tile budget.
`--flow-guide-weight` adds a soft cost for leaving each continuous-flow region.
The default is zero. No step requests a path to preserve a border. A poor
result can still contain thin shapes.

`--flow-grid` sets the external flow grid size (default 256).
`--flow-area-error` sets its relative area-error tolerance (default 0.01).
A less strict tolerance changes the guide geometry, not the final tile budgets.
Record this setting when you compare runs. The external solver can raise small
area targets before solving; its error is not necessarily the error against the
original population budgets. Any failed external run stops the pipeline.

## Optional controls

- `--sites FILE`: use [population sites](population-sites.md) for country costs.
- `--float-islands`: let intact isolated islands move outside the mainland target
  instead of reserving their old cells as holes.
- `--dock-landmasses`: translate separate target pieces until they touch. This
  acts within each source land-border group. It adds no connector cells, but
  can change coasts and positions. Country sites do not move with the pieces.
- `--borrow-coast`: if an interior region cannot grow into empty space, try a
  donor-cell exchange. A neighbour gives one cell to that region and grows one
  cell into empty space. Each country keeps its budget. The search has limits
  of 32 fragment cells and 64 donor-cell choices per step. It can still fail.

These controls are off by default. They are experiments, not acceptance rules.

## Stages

1. Prepare component geometry and run continuous flow, unless geometry was
   supplied. Check the geometry separately. Do not adopt raised minimum areas
   from the external solver.
2. Build one shared footprint for each connected source land-border group.
   Keep its original requested area. Translate isolated island templates near
   the flow sites; do not distort those templates.
3. Assign footprint cells to components by capacity. This stage can split
   regions. A smoothed transport solve is followed by a greedy count correction;
   this is not an optimality certificate.
4. Swap fragment cells without changing counts or the occupied footprint.
   If fragments remain, try to replace them by compact growth of the main piece.
   This changes coasts and can change empty spaces. It does not join the pieces.
5. Reposition isolated islands. Preserve and report existing mainland defects.
   Do not add false contacts or change represented source contacts in this stage.
6. Check and render the world and regional layouts with no graphical display.

## Review files

- `pipeline.json`: stage status, settings, hashes, checks, and limits.
- `layout/review.png`: world image, including topology warnings.
- `layout/metrics.json`: counts, connectivity, borders, and position checks.
- `review/gaps.png`: an empty-space diagnostic, not a classification of water.
- `review/regions/`: regional images at unchanged world positions.
- `repaired/relocations.json`: cells removed and added during fragment relocation.
- Stage logs: timings and solver progress, including iteration limits.

Country holes can contain other countries. They are not necessarily empty
holes in the land union. Both measures are reported. The pipeline never marks
its output as approved for production and does not change `data/cartogram.csv`.
