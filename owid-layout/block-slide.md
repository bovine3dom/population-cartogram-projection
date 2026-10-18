# West Africa: move pieces without redrawing them

[Open the before-and-after images](../examples/auto-cartogram/results/west-africa-block-slide/index.html).

## Purpose

Move Burkina Faso south and a block from Nigeria's western arm north.
Keep existing shapes where possible. Do not repartition West Africa.
The approved layout and H3-MON exports remain unchanged.

This is a named two-country demonstration, not an automatic world placement
policy. The input is the approved clean build. No new geographic data or manual
island assignments are required.

## Two candidates

| Check | Small join adjustment | Strict rigid swap |
| --- | ---: | ---: |
| Burkina Faso moves east | 4 tiles | 7 tiles |
| Burkina Faso moves south | 9 tiles | 10 tiles |
| Burkina Faso tiles | 159, unchanged | 159, unchanged |
| Burkina Faso outline | Exact translation | Exact translation |
| Nigerian block tiles | 155 | 159 |
| Nigerian tiles with one common translation | 151 | 159 |
| Nigerian tiles with a join adjustment | 4 | 0 |
| Nigerian tiles that stay in place | 1,407 | 1,403 |

Nigeria keeps 1,562 tiles in both cases. Every other country stays unchanged.
Both countries and both exchanged blocks remain connected through shared edges.
The combined land mask stays identical, so the moves create no gaps or holes.
There is no rotation or scale change.

The small-join candidate reaches Ghana and Togo. The rigid candidate reaches
Togo but not Ghana. Burkina Faso still touches Nigeria and no longer touches
Mali. These are movement tests, not complete geographic arrangements.

## Method

1. Search integer translations of the existing Burkina Faso mask. Search up to
   one mask width east or west and two mask heights south.
2. Reject a destination that overlaps another country's land or uses an empty
   cell. Reject a move that disconnects a country or its block.
3. Translate every Burkina Faso tile by the same vector.
4. Move the displaced Nigerian tiles in the opposite direction. If old and new
   Burkina Faso overlap, continue a tile's translation chain until it reaches a
   vacated cell. This produces a one-to-one tile movement map.
5. Keep candidates that move a substantial Nigerian block: at least 128 tiles,
   which is 80% of Burkina Faso's tile count, rounded up.
6. Select the closest zero-adjustment swap. Also select a candidate that reaches
   Ghana, moves east as little as possible, and adjusts at most 5% of its block.

The search found 205 candidates under these controls. Ghana is a reference for
this demonstration only. It is not a new rule in the world layout builder.

In the small-join candidate, 151 Nigerian tiles move four tiles west and nine
north. Four tiles move eight west and eighteen north to complete the overlapping
translation chains. The movement image marks these four tiles with purple boxes.
Dark green identifies the Nigerian block; it is not a new country.

The selected block comes from the western arm. It is not a rigid translation
of the entire arm or of all Nigeria. Nigeria's main body stays fixed, but the
combined country outline changes where the block moves. A narrow Nigerian
connection remains west of Burkina Faso in the small-join candidate. This is
one limit of keeping all other countries and the land mask fixed.

## Run

From the repository root, use new output directories:

```sh
julia --project=owid-layout owid-layout/bin/slide-west-africa.jl \
  output/auto-cartogram/owid-clean-v2 \
  output/auto-cartogram/west-africa-block-slide-new

julia --project=owid-layout owid-layout/bin/review-block-slide.jl \
  output/auto-cartogram/west-africa-block-slide-new \
  output/auto-cartogram/west-africa-block-slide-review-new
```

Each candidate has a full-world `cells.csv` and a `motions.csv` with the original
and final position of each moved tile. The report records counts, shifts,
connectivity, neighbours, and input hashes. The renderer writes SVG and HTML in
Julia. The full-world image shows the small-join candidate.

These outputs are layouts, not new H3 mappings. An old H3-to-tile mapping must
not be treated as a fit to the new layout.

## Work log

- Kept the previous border-refit trial separate. Its country-redrawing objective
  did not match the requested shape-preserving movement.
- Added a reversible two-piece translation operation with explicit tile paths.
- Searched placements without moving a third country or changing the land mask.
- Checked the regional and movement images. Burkina Faso retains its original
  outline, including its small projections. The movement overlay makes the
  selected Nigerian block and the four join adjustments explicit.
- Added 25 tests for rigid swaps, overlapping moves, reversibility, connectivity,
  blocked destinations, and the Burkina Faso/Nigeria example. All 246 tests pass.
- Ran the complete trial twice in separate processes. All seven output files are
  byte-identical. See the [repeat checks](../examples/auto-cartogram/results/west-africa-block-slide/validation.json)
  and [test log](../examples/auto-cartogram/results/west-africa-block-slide/tests.txt).
