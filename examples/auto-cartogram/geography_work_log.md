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

## 2026-10-15: work from the preferred margin-one layout

The user selected `protected-water/margin-1/review.png` as the most promising
layout. Keep this footprint as the reference. Its detached groups are Norway
with Sweden, Gibraltar, and the Americas across Honduras/Nicaragua. Finland
remains attached. These are not disconnected pieces within a country.

Added detached-only mode to `dock_true_borders.py`. It moves whole disconnected
landmass parts, not just groups of existing true borders. Every accepted move
must reduce the number of landmass parts. It retains all existing true borders,
does not increase false-border totals, and rejects overlaps.

The first pass joined Norway/Sweden and Gibraltar. A two-tile Peruvian island
blocked the South American move. Added a general rule: independent islands
within 500 km of a source land component move with that component. The nearest
source coast selects the parent; country membership does not. This also moves
nearby Nordic islands with Norway/Sweden.

All three breaks then close. Norway/Sweden move 11 tiles east and two north;
the southern Americas group moves 17 west and nine north; Gibraltar moves four
west and nine north. No connector cells are added. Every component retains its
shape and tile count. Missing borders fall from 66 to 63; false borders stay at
34. Visually checked the world and Europe. The Baltic gap remains open.

Tested island placement separately on this repaired layout. The previous
transport map supplies local coast directions, translated to current component
centres and snapped to current coasts. This is only a placement guide: no old
population weights are transferred to the new layout. Source-proximity island
groups are then restored. Ireland moves north. Long Island moves southeast of
Manhattan: the centroid difference changes from (6.83, 8.05) to (3.83, -3.95).
Reviewed Europe, New York, Indonesia, and Japan/Korea. Japan is not bisected by
Korea. Java is still too far west; this island candidate needs further work.
A ten-percent centre-target mixture did not resolve that problem.

The independent audit of the island candidate confirms zero split source
landmasses. It reports nine possible lost coasts and seven possible false
coasts. Exact component budgets remain unchanged. Seven translation tests and
seven coast-graph tests pass. No production layout or population export changes.

## Explicit inland lakes: source audit and first guide trial

Downloaded the standard Natural Earth 1:10m lake GeoJSON and inspected its
source documentation. The audit records the file hash. Historic and pluvial
lake layers are not used. The country polygons cover the full area of Victoria,
Tanganyika, Malawi, Superior, Baikal, and Titicaca. This is administrative
territory, not a dry-land mask. Existing polygon-hole preservation cannot
recover these lakes.

Added `prepare_lake_guides.py`. It audits all 1,355 lake features, subtracts
selected lakes from the guide land, and exports separate water-guide regions.
The final test selects 48 lakes at thresholds of 1,000 square kilometres and
one estimated display tile. Their total target area is 241 guide units. Land
budgets remain 55,000 tiles. Water has no population budget. Two invalid source
lake rings are repaired and recorded. Smaller lakes remain in the audit.

Lake subtraction also checks existing administrative contacts. DR Congo and
Tanzania are separated by about 32 km after Lake Tanganyika is removed. Their
administrative lake border must not become a required land connection. Fifteen
land guides become multipart after subtraction. These include lake islands;
they need population-component checks before a production mapping is possible.

Ran the optional flow solver on the lake-aware guides. The normal run fails on
Malawi during densification. Disabling simplification and densification writes
an output, but independent validation rejects it: 25 invalid geometries,
17 overlap pairs, and about 451% maximum relative area error. The output exit
status alone is not an approval check.

Added `review_lake_flow.py` with strict validation by default. An explicit
invalid-review option permits diagnostic images only; the report lists each
invalid source geometry and states that repairs do not validate solver output.
Visually reviewed the East African source and diagnostic flow images. The lakes
are visible, but the failed flow is not used to change the preferred layout.
Four lake tests cover cross-border water, existing holes, unchanged land budgets,
water-only contacts, and rejection of invalid solver geometry. The existing
43 shape tests also pass.

Review page: `results/geography/margin-1-followup/index.html`. The rejoined
mainland candidate and the separate island trial are available there. Inland
lakes are not yet restored in their tile layouts. Next, preserve explicit water
regions during local tile allocation and distinguish physical land borders
from borders through lakes. Do not replace margin-one with the failed global
flow or paint lakes over population-bearing tiles.

## 2026-10-15: local lake insertion on the repaired margin-one layout

Added `lake_vacancies.py` and `place_lake_regions.py`. A move shifts tile labels
along a short route to the outer coast. The first cell becomes water. A new
land cell at the route end keeps each component budget exact. Intermediate
cells remain land. No empty channel remains along the route.

Each move must keep components connected and retain existing physical land
contacts. False-contact totals cannot increase. Landlocked components cannot
gain ocean edges. Independent islands stay fixed. Concave sea areas are
protected from new land cells. Each complete lake must touch its main source
shore components. A failed lake trial restores all its changes.

The first three-lake pilot placed no complete lakes. A wider search placed
Victoria and Malawi. The first 48-lake run with that search placed 45 lakes,
but visual inspection found narrow boundary extensions. Added a route cost
that favours boundary corners over one-cell extensions. This removes the most
obvious new extensions in the East African view. It is a preference, not a
proof that all narrow shapes are absent.

Final trial: `output/auto-cartogram/geography-margin1-lake-vacancies-final/`.
Use `--placement-attempts 128 --path-attempts 256`; other settings are defaults.
The input layout is `geography-margin1-rejoined-final`, not the separate island
position trial. The report records settings and input hashes.

- 45 of 48 selected lakes fit, with 220 water display cells.
- Victoria, Malawi, the five Great Lakes, Baikal, and Titicaca are present.
- Tanganyika, Khanka, and the South Aral Sea do not fit. No partial lake remains.
- All 55,000 land tiles and all 481 component budgets remain exact.
- No component is disconnected. The independent audit finds no split source
  landmass. Administrative border counts remain 63 missing and 34 false.
- The source-coast audit reports 14 possible lost coasts and seven possible
  false coasts, unchanged from the repaired mainland base.
- All newly empty cells have a named lake. Original holes remain unchanged.
  The generic region-hole count rises from seven to 25 because it includes
  real lakes. It is not a count of new phantom holes.

Visually checked Africa before and after, Europe, North America, and the world
view. The Baltic gap remains open. Lake positions are approximate. The Great
Lakes need joint relative-position checks; shoreline membership alone does not
check the order of countries around a lake. Tanganyika needs local boundary
adjustment or template deformation. Do not force it through a thin land path.

Seven new tests cover exact budgets, rollback, fixed islands, route limits,
connectivity, protected sea, and an end-to-end cross-border lake fixture.
All 170 Python automatic-cartogram tests pass. The renderer rejects lake cells
that overlap population tiles. Lake-island population components and a new
population mapping remain future work. The published H3-MON map is unchanged.
