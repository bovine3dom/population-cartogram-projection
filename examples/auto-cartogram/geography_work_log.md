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

## 2026-10-15: first water results and stronger checks

Both initial water trials finished. Their area budgets are exact and all
individual components remain connected. That check was not sufficient:
visually, Norway and Sweden become detached from the rest of the mainland.
Added a separate source-landmass connectivity check. The baseline has no split
source landmasses. Margins zero and one add respectively four and three parts
across two source landmasses. These are regressions; neither trial is approved.

The margin-one trial gives Estonia, Latvia, and Lithuania respectively two,
one, and four edges beside exterior water. Paraguay has zero. Across the whole
map, possible lost coasts fall from 21 to 14. Possible false coasts remain at
seven: fixing Paraguay does not fix all landlocked components. Bolivia is among
the remaining flags. Do not judge a candidate only by the named examples.

Reviewed world, Europe, South America, and Japan images for margin one, and
Europe and South America for margin zero. The sea mask restores real water but
also changes regional shapes and land connections. Existing source holes must
not automatically be called phantom holes. Review page:
`results/geography/protected-water/index.html`.

Two guide-weight-32 trials are running to test stronger shape guidance. The
first completed European image is not acceptable: Norway moves to the east of
Sweden. Fragment repair can discard the part that carries a useful geographic
relationship even when the final country is connected.

Added an optional soft cost for assigning exterior-coast cells to components
with no sampled source coast. Enclosed lakes are excluded from this cost. The
cost is general, not a Paraguay or Bolivia rule. It records the classification
file hash and weight. Later repair can still change access, so this is not a
final-position guarantee. Two weight-1000 trials are running. The partition
suite passes 26 tests, including an interior-assignment fixture. The geography
suite passes seven tests, including split source landmasses.

## Restore island groups after the transport-coast trial

Applied the existing source-proximity archipelago step after v6. It does not use
country-membership links. Visually reviewed Japan, Indonesia, and New York.
Japan's main islands are more coherent again. The New York relationship also
improves: Long Island moves from northeast of Manhattan to southeast of it in
tile-centroid terms. The shortest tile-centre distance stays two tiles, so the
issue was not simply excess space between the closest cells. Ireland retains
its earlier northward move because shared land-border groups are not moved by
this last step. Indonesia still needs work.

Saved the candidate and baseline New York images under
`results/geography/coast-graph/v6-cohesion/`. No population map is replaced.

## 2026-10-15 17:15 UTC: local changes instead of a full rebuild

The stronger-guide and inland-cost trials have finished. None is approved.
The inland-cost, margin-one trial reduces possible lost coasts to 13 and
possible false coasts to five. But it still adds three landmass parts.
The near-raw-footprint trial has 29 possible lost coasts and four possible
false coasts. It adds two landmass parts. Reviewed its Europe and South America
images: the northern connection is thin and Chile moves south of Argentina.

Added an optional flow-centres test. This keeps continuous-flow centres instead
of fitting native population centres with a global linear transform. The
partition suite passes 26 tests. The world trial still produces detached Nordic
regions in the Europe image. This option alone is not a solution.

Confirmed a repair failure in the stronger-guide trial: the repair step removed
13 western Norway tiles and added 13 tiles beside the eastern fragment. Do not
use final component connectivity as proof of geographic accuracy.

Added `refine_geography.py` to test paired tile exchanges on the good baseline.
It keeps exact component counts, checks component topology, and rejects moves
that split a source-connected landmass. Isolated islands and small landmasses
stay fixed. No required-border paths are built. Four tests cover accepted
moves, split rejection, rollback, fixed regions, and coast costs.

Reviewed Europe and South America at guide weight one, round 50, and guide
weight 0.05, round 175. Both remain experiments. The stronger guide creates a
thin Uruguay extension. The weaker guide removes that extension but does not
restore the Baltic. It also makes some countries too rectangular. General
landmass connectivity cannot ensure that the right countries share a border.

The round-50 audit confirms zero split source landmasses and exact counts.
Possible false coasts fall from seven to four, but possible lost coasts rise
from 21 to 23. Missing contacts rise from 59 to 65. Do not select this result.
The two bounded runs stopped at their time limits after rounds 64 and 182;
the reviewed checkpoints are complete, but the requested 200-round runs are not.
Images are in `results/geography/guarded/`.

Next: preserve useful existing source contacts during exchanges. Add explicit
water-side relationships rather than only a cost for empty cells. Keep the
island placement tests separate until the mainland result passes review.

## Contact guards and a local water-cost trial

Added an optional guard that retains existing true borders. It also retains
true borders gained during the run. Six tests pass, including contact-count
rollback checks. The 75-round trial reduces missing contacts to 53 and false
contacts to 44. Possible false coasts fall to two, but lost coasts rise to 26.
Reviewed Europe and South America. The Baltic still fails, and a new gap appears
in northern South America. This trial is not approved.

Added a soft water cost from the raw flow raster. At weight 200, the Baltic gap
opens further. But Sweden grows a thin connection towards Germany, and other
coasts gain large notches. Reviewed both regions and rejected this result.
Keeping a landmass connected can retain the wrong connection.

A graph check explains the Nordic problem in the baseline. Norway and Sweden
form a 99-tile group through true tile borders. Finland is a separate 37-tile
group with no true tile border. Their apparent mainland connections are false
contacts. Next test: translate small groups to true neighbouring groups. Use
whole shapes, not connector paths, and reject overlaps or landmass splits.

## 2026-10-15 17:43 UTC: true-border translations and native shapes

Added `dock_true_borders.py`. It groups components by true borders that exist
in the tile layout. Small groups can move as rigid shapes towards missing true
neighbours. The largest true-border group in each source landmass stays fixed.
Moves cannot increase the number of false contacts, lose existing true contacts,
overlap other shapes, or split a source-connected landmass. No connector tiles are added.

The first trial moved Finland towards Norway and Sweden but could not then
join Russia. Giving the main group priority restored Finland's Russian border,
but put Sweden northeast of Finland. Reviewed and rejected both arrangements.
Added general axis guards from source component bounds. These keep Sweden west
and south of Finland, but no rigid placement then joins all three countries.
This is evidence that their shapes and positions must change together.

The axis-guarded translation trial moves five groups. It also removes false
contacts between Monaco and Lebanon/Syria, and between the UAE and Iran/Pakistan.
These were errors between specific source components, not just country labels.
Missing borders fall from 59 to 54; false borders fall from 55 to 44.
Possible lost coasts fall from 21 to 18. This is not an approved replacement.

Added optional native shape guidance to local exchanges. Each source outline
is scaled to its tile area and centred on its starting tile group. Tested
weight 10, flow weight zero, retained true borders, and 75 rounds after the
translation trial. A second translation pass gives 46 missing and 41 false
borders, 19 possible lost coasts, and three possible false coasts. The independent
landmass audit confirms zero splits. Budgets remain exact.

Visually reviewed the world, Europe, South America, Japan/Korea, and Indonesia.
Chile and Italy have more useful outlines. The Baltic is still not satisfactory.
A thin connection between North and South Korea is also visible. Thus this
candidate is not ready for production, despite the better aggregate checks.
The earlier island-only candidate is not merged into these mainland tests.

The review page is `results/geography/guarded/index.html`. It includes a world
image, regional images, compressed tile layouts, settings, and audits. Seven
refinement tests, four translation tests, seven geography tests, and 26 partition
tests pass. The published H3-MON map remains unchanged.

The next algorithm needs joint movement and deformation of neighbouring groups.
It must retain the correct side of water and allow false land connections to
be replaced. Do not select a result from border totals alone.
