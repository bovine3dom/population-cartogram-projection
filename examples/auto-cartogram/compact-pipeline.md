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
  donor-cell exchange. Adjacent regions can pass cells through a chain until
  the last donor grows into empty space. Each country keeps its budget. The
  search has limits of 32 fragment cells, 64 donor-cell choices per step, and
  four regions per chain. A failed exchange changes nothing. It can still fail.

These controls are off by default. They are experiments, not acceptance rules.

`relax_flow_areas.py` tests a different continuous guide. Within each source
land-border group and source continent label, it blends requested guide areas
with geometric-area shares. A blend of zero keeps the requested areas; a blend
of one gives that group uniform density. Isolated components keep their areas.
The output records every changed guide area and any unambiguous country-code
fallback needed for dissolved map units. It does not change source geometry,
adjacency, population groups, or final tile budgets.

These relaxed areas are **not population targets**. Use them only for the
external flow guide. Then supply that geometry to the tile pipeline with the
original component inputs. Transcontinental source labels can affect the result.
Inspect it before selection; the guide is not an approved population map.

`partition_land.py --regions FILE` tests a two-level assignment. The CSV must
contain one `component_id,region` entry per component. First assign each region
its total budget within its source land-border group. Then assign countries
inside that region. This keeps all original component budgets. It does not
preserve borders or guarantee useful shapes. The pipeline wrapper does not yet
expose this option. Initial tests still have poor shapes and positions.

`compact_regions.py --fixed-footprint` tests basic country-to-country boundary
exchanges after partition repair. It keeps all occupied cells and empty spaces
fixed. It requires exact starting counts and connected regions. Existing region
holes are permitted only in this mode; each region's hole count must stay fixed.
Such holes can contain other countries or existing water. This mode cannot fix
an existing empty land hole. It cannot be combined with count fitting or regrowth.
Border errors can remain. Use `--land-only` to freeze isolated island templates.

## Mainland-only flow control

`prepare_flow.py --mainland-only` excludes components with no represented source
land-border neighbours from the continuous solve. It does not remove their
population or tiles from the final layout. Some small islands have land borders;
those components remain in the solve. No country-ID link joins overseas parts.

This tests an upstream effect: the external solver raises some small guide area
targets. Keeping islands separate only after that solve does not remove their
influence on its deformation. This is a hypothesis, not a confirmed cause of
the poor continent shapes.

Pass the resulting partial geometry to `partition_land.py` with `--sites FILE`.
Only isolated components may be absent. Their intact templates are placed near
population sites aligned to the represented flow centres. The scale uses only
the budgets of components present in the flow. Final partition budgets still
include all components. The pipeline wrapper accepts this control with
`--mainland-only --sites FILE`. Its geometry check rejects missing components
that have represented land borders.

For the current compact control, add these options to the pipeline command:

```sh
--mainland-only --sites output/auto-cartogram/world-55000-population-sites/sites.csv \
  --stretch 1.2 --flow-guide-weight 8 --float-islands --dock-landmasses \
  --borrow-coast --fixed-border-rounds 100 --shared-islands
```

`--fixed-border-rounds` changes internal borders without changing occupied cells.
`--shared-islands` restores source-shaped templates for small shared landmasses.
It preserves each component budget. Neither option guarantees good geography.

For a transformed mesh guide, `--sites-in-flow` uses supplied sites in the guide's
coordinate system. It requires `--sites` and `--flow-geometry`. Do not use native
population coordinates with this flag. See [the mesh experiment](mesh-guide.md).

## Fixed-coast anchor control

`place_islands.py --fixed-land-anchors` permits an island to use a nearer fixed
coast even if that coast's component has less population. The default hierarchy
uses only larger populations to ensure that an anchor is already placed. Fixed
components are already placed, so that restriction is not needed for them.

This tests errors such as Sulawesi being anchored to Mindanao instead of nearer
Borneo, or Australia being anchored to Java instead of nearer New Guinea.
The choice uses source coast distance, not country identity. All fixed cells,
island shapes, counts, and represented land contacts stay unchanged. Collision
removal can still put an island in a poor position. This option is a separate
control, not a new default.

The recorded pipeline also accepts `--fixed-land-anchors`. It repeats island
placement after shared-island correction, so it uses the corrected fixed coasts.
Combine it with `--archipelagos --bridge-groups --archipelago-gap-fraction 0.35`
to test the four-resolution island candidates. Group merging requires
`--archipelagos`. Both new options remain off by default.

## Nearby island groups

The separate `restore_archipelagos.py` control addresses islands placed on the
wrong side of a nearby mainland. It groups nearby source components, not country
IDs. It places each group together without connector cells. Mainland cells and
island shapes do not change.

```sh
p=output/auto-cartogram
"$p/geometry-env/bin/python" examples/auto-cartogram/restore_archipelagos.py \
  "$p/world-55000-dissolved-input" "$p/world-55000-guide8-border16" \
  "$p/world-dissolved/polygons.geojson" "$p/world-55000-island-group-test"
```

The optional `--bridge-groups` control merges nearby groups through small source
islands. It changes group membership only; it adds no cells or lines. A group can
merge into the group of its root's nearest larger island if a close pair of source
coasts joins them. Roots whose nearest larger component is land remain separate.
This tests cases where small islands lie between two large islands, but the
population hierarchy divides them into different groups.

The default source-gap threshold is 0.2 times the square root of the larger
island's source area, where larger means higher population. Groups need at least 16 tiles. Definite source-axis
separations from land within approximately 500 km constrain group translation.
These distances use Equal Earth planar coordinates, not geodesic distances.

The maximum group translation is twice the square root of its tile count.
Conflicting bounds, blocked placements, and excessive translations leave the
whole group unchanged. `archipelagos.json` records these failures. This safety
limit prevents some extreme moves; it does not prove good positions. Review
Japan, Indonesia, the Philippines, and other affected groups before selection.
To include this control in a recorded pipeline run, add `--archipelagos`.
Use `--archipelago-gap-fraction 0.35` to test the wider grouping that also keeps
small nearby Japanese islands with the main group. Other island groups can move.
The control remains off by default.

The pipeline does run `review_island_separation.py` as a diagnostic. For each
nearby-island parent pair, it checks the shortest tile-centre segment for land
in between. It adds no lines or cells to the map. This check detects the Kyushu
placement defect that aggregate border counts missed. It checks only nearby
pairs and blockers with source land borders. A warning needs visual review;
zero warnings do not prove correct island placement.

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
- `layout/island-separation.json`: nearby island pairs with land in between.
- `review/gaps.png`: an empty-space diagnostic, not a classification of water.
- `review/regions/`: regional images at unchanged world positions.
- `repaired/relocations.json`: cells removed and added during fragment relocation.
- Stage logs: timings and solver progress, including iteration limits.

Country holes can contain other countries. They are not necessarily empty
holes in the land union. Both measures are reported. The pipeline never marks
its output as approved for production and does not change `data/cartogram.csv`.
