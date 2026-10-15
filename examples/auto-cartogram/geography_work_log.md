# Geographic relationships: work log

## 2026-10-15: baseline checks

Keep the current 55,000-tile layout and its population export unchanged.
Test general rules. Do not add position rules for named countries.

Added `review_geography.py`. It measures tile edges beside exterior water and
beside enclosed water. Exterior water must have a four-neighbour path to the
outer frame. A diagonal opening does not qualify. It also checks the four
nearest source components for each represented component. It reports source
box separations that the tile boxes no longer preserve.

The first all-pairs geometry search exceeded its 180-second limit. Replaced it
with a spatial index and an expanding distance query. The complete check then
finished within the same limit. Five unit tests pass.

Baseline results:

- 1,315 nearby component pairs; 180 pairs have lost a source box separation.
- 60 components have no edge beside exterior water.
- Estonia, Latvia, and Lithuania each have zero exterior-water edges.
- Paraguay has eight exterior-water edges.

These counts are measurements, not a quality score. Real landlocked components
must have no ocean access. Enclosed water can be a lake or a defect. Source box
separation can be too strict for distorted shapes. Equal Earth distance is not
geodesic distance, and the antimeridian needs separate care.

Reports and input hashes:
`output/auto-cartogram/geography-baseline-55000/`.

## Placement rule review

`place_islands.py` selects one nearest eligible coast and places islands in
population order. It maps a source coast point onto the resized tile shape.
This does not preserve the island's position against several neighbours.
A change in the anchor shape can move an island even with no packing conflict.
This is a mechanism to test, not yet a confirmed cause for every reported case.

`restore_archipelagos.py` adds nearby groups and axis constraints. It does not
preserve the full set of regional coast relationships. It keeps components
with land borders fixed, which can restrict shared islands.

## Next experiments

1. Derive source coastal access from the full source geometry. Include
   components with no tiles. Compare source access with tile water access.
2. Represent important sea passages explicitly during mainland placement.
   Keep passages open without adding thin land paths or large empty gaps.
   Do not treat all water as a defect to fill.
3. Derive island targets from several nearby coast points. Fit local position
   changes from source geometry to the mainland layout. Place nearby islands
   together, then check collisions and relative order.
4. Check whether Manhattan and Long Island have separate represented groups
   before treating their positions as independent variables.
5. Compare world and regional images with the unchanged baseline. Check the
   Baltic, Paraguay, Ireland, New York, Indonesia, and Japan. Retain exact tile
   budgets, separate island populations, and the existing Japan correction.

No placement rule has changed in this first step.

## 2026-10-15: coast checks and five island trials

Added `review_source_coasts.py`. It uses all 4,274 source components, including
those with no tiles. It samples exterior rings and checks whether another
component covers each sample within a small tolerance. It does not prove source
water connectivity. Tests at 512 and 1,024 samples give the same totals:
21 possible lost-coast components and seven possible false-coast components.
The Baltic states and Paraguay are among these flags. This test uses no country
exceptions. Tests cover isolated, shared-border, and surrounded source shapes.

Added `place_coast_graph.py` as a separate experiment. Shared land-border groups
move as rigid bodies. Existing tile contacts are also kept within each body.
Three large bodies stay fixed. Several nearby coast relations contribute to a
joint translation solve. Exact-shape packing reserves the other bodies' current
cells, including small islands not yet placed. This avoids consuming their only
available space. Tile budgets, body shapes, and all existing contacts stay
unchanged. Existing contact defects are not repaired by this experiment.

Five completed trials:

| Trial | Change | Island axis flags | Country axis flags |
| --- | --- | ---: | ---: |
| Baseline | Current published layout | 513 | 185 |
| v1 | Four nearest bodies; coast and centre targets | 388 | 188 |
| v2 | Keep selected source centre orders already present | 384 | 184 |
| v3 | Prevent small islets from hiding larger anchors | 383 | 178 |
| v4 | Remove whole-body centre targets | 383 | 178 |
| v5 | Map coast points through individual components | 387 | 185 |

All trials keep 55,000 tiles, zero count error, and connected components. The
baseline's 59 missing contacts, 55 false contacts, and two regions with holes
remain. These counts do not establish geographic quality.

Visually checked Europe, Indonesia, and Japan for all five trials. Reject all
five as replacements. Ireland moves north, but the early trials scatter parts
of Japan. The later trials still place Sumatra too far west and weaken the
Japanese island arrangement. Lower axis-flag counts do not justify these
regressions. Whole-continent centre targets are unsuitable for local coasts.
Component-level coast frames reduce that problem but are not sufficient.

The regional-anchor search initially exceeded its 180-second limit. A stack
trace located repeated detailed geometry distance tests. Cache pair distances,
skip searches from fixed continents, and simplify projected source geometry at
0.00001 unit radius. The later runs finish within the limit. This tolerance and
the anchor area threshold are recorded in each completed run.

Manhattan and Long Island are separate represented components. Point-in-polygon
checks identify `USA:cc58c4c14d03150e` (10 tiles) and
`USA:c78710e5bfb7f314` (52 tiles). Their relative placement can be changed without
combining their populations.

Review files: `results/geography/coast-graph/`. Full runs:
`output/auto-cartogram/geography-coast-graph-v1/` through `v5/`.
No new layout or population mapping is published.

Next: test local coast correspondence and limits on changes in island-to-island
distance. For mainland seas, the current fixed footprint cannot restore lost
water. The footprint builder must retain source water passages before it assigns
country cells. Do not cut arbitrary one-cell paths through the final layout.

## 2026-10-15: locate water loss in the pipeline

Checked the raw continuous-flow raster at the baseline scale and stretch.
Estonia, Latvia, and Lithuania have zero exterior-water edges, but respectively
seven, eight, and two edges beside enclosed water. The Baltic still has water
in this raster, but the strait is not resolved. The later smoothing step removes
that water. Paraguay has zero water edges in the raw raster. Its false coast
appears later.

Added optional water protection to the footprint builder. A morphological
closing identifies concave water in the raw flow raster. Exclude that water
from the land target. An optional margin widens the excluded area. Keep the
original area quota and place the displaced land elsewhere. The default remains
off. Protection requires a flow guide and cannot be combined with docking.
This is an experiment, not a source-water connectivity proof. Later repair and
island stages can still affect water and must be checked.

`run_water_trials.sh` runs two 55,000-tile candidates with closing radius eight
and margins zero and one. Each has a two-hour limit and must stop before the
supplied UTC deadline. It records exit codes, renders regional images, and does
not publish a map. The partition test suite passes 25 tests, including a new
bay-protection fixture. Numerical and visual results are still pending.

## Transport-based coast positions

Trial v6 uses the existing island-group H3 mapping to estimate local coast
positions. For each represented component, it interpolates nearby source
fragments' mapped centres and selects a nearby tile boundary point. Source
fragments assigned from other components are not used for that coast frame.
The adapter checks every target coordinate against the starting layout and
checks local source weight sums. It records all input hashes. It does not
change any transport weights or population assignments.

The adapter and coast-graph tests pass seven tests. They include rejection of
a different target layout and incomplete source weights. Visually reviewed
Europe, Indonesia, and Japan. Hokkaido stays nearer northern Honshu than in the
early trials, but the Indonesian arrangement is still not a clear improvement.
Do not replace the baseline with v6. It is available beside the earlier trials
in the geography review page.
