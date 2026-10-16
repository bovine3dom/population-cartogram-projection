# Margin-one lake layout: change only the starting flow projection

## Reference

Use [this exact lake layout](results/geography/margin-1-followup/local-lakes/review.png).
Its source is `output/auto-cartogram/geography-margin1-lake-vacancies-final`.
The separate regional Mercator and border-release experiments are not the
reference. They changed the fitting method and did not answer the request.

The reference has 55,000 land tiles, 481 components, 45 named lakes, and 220
empty lake cells. It has 63 missing and 34 false administrative contacts.

## Controlled change

`prepare_flow.py` now accepts `--projection mercator`. Its default remains
Equal Earth. Both options use the same source component polygons, tile
budgets, represented-mainland selection, and source holes. Mercator uses the
spherical formula, rejects the poles, and does not clip latitude.

`run_margin1_projection.py` copies settings from the saved reference records:

1. Prepare the mainland flow input with the selected starting projection.
2. Run the same external continuous-flow command and options.
3. Run the margin-one pipeline with stretch 1.2, flow guide weight 8, sigma 4,
   300 partition iterations, water radius 8, and water margin 1.
4. Keep the existing island stages and 16 fixed-footprint border rounds.
5. Run the same detached-mainland repair: four rounds, radius 64, maximum
   group size 10,000, and nearby coastal islands within 500 km.
6. Insert the same requested lakes with 128 placement attempts and 256 path
   attempts. Keep the other reference lake settings.
7. Render the world and regional views. Compare counts, borders, and lakes.

No stage uses `fit_mercator_shapes.py` or `release_regions.py`. No stage adds
permission to remove a border. The experiment changes the starting mainland
flow geometry, not the fitting objective or contact rules.

All downstream source-coordinate frames, population sites, island templates,
coast rules, and lake guides remain those of the reference. The fitting code
already treats the supplied flow as a separate guide frame. Do not relabel
Equal Earth source coordinates as Mercator coordinates.

The runner checks hashes of the reference input chain before it starts.
It records the external binary hash, command, copied settings, and final
comparison. Output is never approved or exported to production automatically.
The existing reference and H3-MON mapping are not modified.

## Reproduce

Use new output directories. Run from the repository root:

```sh
OPENBLAS_NUM_THREADS=2 OMP_NUM_THREADS=1 \
  output/auto-cartogram/geometry-env/bin/python \
  examples/auto-cartogram/run_margin1_projection.py \
  output/auto-cartogram/margin1-mercator-new --projection mercator
```

For a matched control, use `--projection equal-earth` and another output path.
The whole experiment needs the saved reference records and the existing
optional external flow binary. It does not install new dependencies.

The default Equal Earth preparation reproduces the archived starting geometry
byte for byte. The Mercator and Equal Earth area tables are identical. A fresh
Equal Earth flow run does not reproduce the old solved geometry exactly, so
compare the Mercator run with both the saved preferred layout and the fresh
Equal Earth control. Do not attribute control-run changes to Mercator.

All 201 tests pass. Three new tests check unchanged default projection,
unchanged component budgets and holes, and unchanged mainland selection.
The existing tests also check Mercator reference coordinates and polar limits.

## Completed comparison

[Open the checked images](results/geography/margin-1-mercator/index.html).
Both runs completed. Neither replaces the preferred reference.

| Layout | Missing contacts | False contacts | Split source landmasses |
| --- | ---: | ---: | ---: |
| Preferred reference | 63 | 34 | 0 |
| Fresh Equal Earth control | 61 | 39 | 1 |
| Mercator starting flow | 64 | 37 | 2 |

All layouts have 55,000 tiles, exact budgets for 481 components, 45 named
lakes, and 220 empty lake cells. Every individual component is connected.
Mercator leaves a 178-tile Malaysian component and a 30-tile Canadian
component detached from their source landmass groups. The control leaves
Norway and Sweden detached together. These are regressions, not new permission
to break borders.

The Mercator run loses Syvash and gains the South Aral Sea in the accepted lake
set. The Equal Earth control keeps the reference lake set. Estonia, Latvia,
and Lithuania retain exterior-water edges in the Mercator run. Paraguay has
none. The counts and lake cells were checked independently before publication.

Visual review covered world views, Europe, African lakes, North America, and
Japan/Korea. The joined layout remains intact at the broad regional scale,
but Russia, China, and India still have substantial shape distortion. The
projection change alone does not restore their native outlines. The original
preferred layout remains the reference. The cause of the fresh Equal Earth
flow's repeatability difference has not yet been established.
