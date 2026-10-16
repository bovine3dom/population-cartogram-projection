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
Lakes need joint relative-position checks: Ontario is west of Huron in this
trial, which is wrong. Shoreline membership alone does not check the order of
countries around a lake. Tanganyika needs local boundary
adjustment or template deformation. Do not force it through a thin land path.

Seven new tests cover exact budgets, rollback, fixed islands, route limits,
connectivity, protected sea, and an end-to-end cross-border lake fixture.
All 170 Python automatic-cartogram tests pass. The renderer rejects lake cells
that overlap population tiles. Lake-island population components and a new
population mapping remain future work. The published H3-MON map is unchanged.

## Lake display correction

Removed the blue review overlay at the user's request. Lakes now show the same
empty background as the sea. The overlay never used country tiles, but it made
that distinction unclear. Land cells, lake positions, and population budgets
are unchanged. Lake records remain separate for validation only.

Updated the world and regional review images. Visually checked the Africa
image. A regression check confirms that lake metadata adds no painted shapes
and that a lake record cannot overlap a population tile. All 170 tests pass.

## 2026-10-15, 20:32 UTC: selective border separation

Started a separate experiment for the user's proposed eight-hour window.
The current layout and H3-MON export remain unchanged. Details, sources,
settings, and limits are in `sparse_borders.md`.

Read the 2021 Gastner, Perrault, and Feng conference abstract on balancing shape
and contiguity. It supports testing selective separation, but does not supply
this population rule. Its connecting lines and fixed-size nodes are not used.

Added a two-sided border-corridor population audit using existing H3-5 sources.
The strict limits admit 74 of 348 component pairs. Wider limits admit 98.
Kazakhstan–Russia and Mongolia–Russia pass the strict test. China–North Korea
and China–Vietnam do not. China–Russia passes only the wider test.

Added matched local-refinement tests with exact component budgets, protected
non-eligible contacts, no new false contacts, a limited gap region and budget,
and fixed lake cells and immediate shore labels. Independent islands stay
fixed. A separate review measures native-outline overlap and newly enclosed
blank cells. New blank gaps are not called geographic water.

Ran a ten-round pilot and four 100-round tests. Visually inspected the input,
the wider relaxed result, and its matched control in Eurasia. Both relaxed
tests have slightly worse independent shape scores than their controls.
The strict relaxed test loses Sweden–Finland. The wider test loses six
contacts but does not provide a clear Russia/China improvement over its
control. Do not promote these candidates or claim that separation has helped.
Started matched 400-round tests to check whether short runs explain this result.

## 2026-10-15, 21:20 UTC: longer runs and opening trials

Both 400-round runs completed. The wider relaxed run still scores slightly
worse than its matched control: 0.40038 versus 0.39997. It loses seven existing
contacts. Inspected both Eurasian views. The native-outline score improves,
but some regional relationships become less clear. Do not use that score alone.

Added a bounded opening phase before normal refinement. It tests whether a
short-term energy barrier prevents useful separation. Failed openings restore
all changes. Successful openings retain exact budgets and all other existing
true contacts. Refinement may close the opened border again.

Ran three 100-round opening trials and a new matched small-gap control.
The large-component trial opens China–Russia and slightly improves Russia's
outline against the wider control. However, it creates 100 newly enclosed
empty cells, versus 35 in that control. Rejected this trade-off.

A smaller gap allowance reduces the opening trial to 28 new enclosed empty
cells, versus 24 in its matched control. It temporarily opens Kazakhstan–Russia;
that border reconnects during refinement. Russia improves slightly more, but
China is unchanged and the total shape score remains slightly worse.
Visually inspected the opening trials and the small-gap comparison.

A 50 km corridor audit admits 67 pairs instead of 74 under the strict limits.
Kazakhstan–Russia and Mongolia–Russia remain eligible. China–Kazakhstan does
not. The threshold decision depends on the corridor scale.

Independent geography checks found an additional problem: even the protected
400-round control has a detached UAE after a false contact is removed. Its
true contacts were already missing. Existing-contact guards alone do not
preserve all current landmass connections. This is recorded, not hidden by the
new permission to separate sparse borders.

All 182 tests pass. No trial replaces the current layout or population export.
The next method needs source-segment population constraints, joint regional
moves, and relative-position checks. Further local iterations alone are not
a supported improvement. Review gallery: `results/geography/sparse-borders/`.

## 2026-10-16: large regional moves

Corrected the experiment after the user requested much larger gaps. Added
`release_regions.py` and five tests. Regional groups use border-corridor
population weights. Lake shores and nearby island chains move together.
Each region can move far from its old centre. Exact packing preserves broad
source-centre order. It does not add connecting paths.

The first grouping split South America too much. A single global population
weight scale reduced this problem. The final spacing tests use 65 groups.
They lose 40 existing true contacts, including 20 that fail the earlier
sparse-border test. This broader permission is explicit in the reports.
Mainland Russia–China distance increases from one tile spacing to 41.62 at
spacing 1.1 and 48.10 at spacing 1.3.

Reviewed world images and Eurasia, Africa, and Indonesia details. Russia and
China now occupy separate parts of the map. Japan stays together. African
lakes remain empty. West Africa separates too far from the rest of Africa.
The widest test adds too much ocean space. Coarse-group trials failed packing
constraints; they are not valid layouts.

After 150 shape-refinement rounds, outline error falls from 0.42690 to
0.40372. All 55,000 tiles and 481 component budgets remain exact. All 45 lakes
retain 220 empty cells. Six new enclosed empty cells remain a defect.
All 187 tests pass. No production layout or H3-MON mapping changed.

Method and commands: `regional_release.md`. Next: joint regional placement
with explicit costs for lost populated borders and nearby coast errors.

Published four world layouts and regional details in
`results/geography/regional-release/index.html`. The gallery includes exact
tile archives, reports, and checksums. Independent archive checks confirm all
budgets and empty lake cells. The refined mainland Russia–China distance is
56.92 tile spacings. The widest rigid trial reaches 158.90, but its excessive
empty space makes it a poor candidate.

## 2026-10-16: fresh shapes from Equal Earth and Mercator

The user correctly noted that rigid regional moves retained the distorted
shapes. Added `review_projection_shapes.py` to compare fresh shapes before
placement. It uses the largest represented component of each selected
country. The default selection is Russia, China, India, and Canada.

Both projections use the same existing component population tile budgets.
Each projected outline is scaled uniformly to that area. Spherical Mercator
uses the formula in the PROJ documentation. It does not clip latitude; it
rejects the poles. This is a diagnostic projection option, not a change to
the production geometry preparation or population coordinates.

Visually checked all four comparisons. Mercator gives Russia a less flattened
outline. Both projections retain recognizable China and India shapes before
placement. Canada has only 203 tiles in its largest component, but the fresh
shapes still retain Hudson Bay better than the current layout. Arctic islands
are not in this comparison. The result supports starting from fresh shapes;
it does not establish that those shapes will fit together.

The growth helper does not preserve lake holes. These diagnostic templates
must not replace the lake-aware layout. The next placement test needs fresh
shape targets and explicit empty-lake constraints. All 191 tests pass,
including four projection tests. Production maps are unchanged.

Gallery: `results/geography/projection-shapes/index.html`. It includes source
outlines, fresh tiles, current shapes, exact tile archives, and input hashes.

## 2026-10-16: fit fresh Mercator shapes

Added `fit_mercator_shapes.py`. It starts from original projected outlines,
not the old tile shapes. Component budgets stay exact. The first test covers
26 Eurasian mainland components and 25,845 tiles. A second test covers the
largest Canadian, United States, and Mexican components with 3,317 tiles.
Named lakes and secondary islands are explicitly outside this diagnostic.
No production layout or mapping changed.

The first geometric-centre fit put Mongolia south of China. Soft position
penalties did not prevent this. Exact ordered packing then failed in some
trials. Added hard linear direction constraints during fitting and explicit
spacing retries during final packing. These failures remain recorded in
`mercator_fit.md`; they are not successful candidates.

Population-centred positions work better in the checked regional fit. The
source coordinates are inverted from Equal Earth and projected into Mercator
before their population-weighted means are computed. Russia moves west near
Europe without a named-country placement rule. All fresh shapes stay intact.

At border release scale 8, final packing requires no expansion. The largest
packing displacement is 1.41 tiles. Russia, China, and India retain recognizable
outlines, and Mongolia is on the correct side of China's centre. However, only
four of 46 true contacts remain. Nineteen removed contacts fail the earlier
sparse-border test. This is not an acceptable final topology.

Release scale 24 creates excessive gaps after 1.6-fold packing expansion.
The quadratic control fails to converge and is labelled as a failed iterate.
The North America test retains Hudson Bay but neither shared land border.
Visually reviewed all four fits. Empty lakes and island relationships must
return before a whole-world trial. Next: bounded shape deformation and stronger
costs for losses along populated border segments, not more rigid separation.

All 198 tests pass. Method and commands: `mercator_fit.md`.
Review gallery: `results/geography/mercator-fit/index.html`.

Independent archive checks confirm exact budgets, connected components,
unchanged fresh template shapes, and zero false contacts in all four outputs.
The failed control remains labelled as non-converged. In the scale-8 Eurasia
fit, 22 border pairs have nearest tile centres within three tile spacings,
including the four retained contacts. Both North America border pairs also
pass that distance check. These are possible targets for limited deformation,
not additional retained borders. Saved tiles and reports include checksums.

## 2026-10-16: correct the Mercator experiment

The user clarified that the reference is
`results/geography/margin-1-followup/local-lakes/review.png`. The regional
shape-first solver was the wrong method. Return to the existing margin-one
fit, mainland repair, and lake insertion. Change only the starting mainland
flow projection. Do not add new border-release rules.

Added an optional Mercator projection to `prepare_flow.py`, with Equal Earth
still the default. Reused the tested Mercator formula instead of duplicating
it. Added `run_margin1_projection.py`, which reads the exact reference settings
and validates their input hashes. It leaves all downstream fitting, island,
border, and lake rules unchanged. No production file changes.

Started matched Equal Earth and Mercator runs. Both continuous flow guides
passed the pipeline checks and reached partitioning. The Equal Earth starting
geometry matches the archived input byte for byte. Both projections have
identical tile-area tables. The fresh Equal Earth solved geometry differs from
the archive; compare both new runs with the preferred reference rather than
attributing all changes to projection. All 201 tests pass.

Method: `margin1_projection.md`. Jobs and logs:
`output/auto-cartogram/margin1-projection-jobs/`. Outputs:
`output/auto-cartogram/margin1-{equal-earth,mercator}-start/`.

Both corrected runs completed with exit code zero. Mercator has 64 missing
and 37 false administrative contacts; the fresh Equal Earth control has 61
and 39. The preferred reference has 63 and 34. Both new runs retain exact
55,000-tile budgets and 481 connected individual components. Both place 45
lakes with 220 empty cells. Mercator loses Syvash and gains the South Aral Sea;
the control keeps the reference lake set.

Independent geography checks found two remaining split source landmasses in
Mercator: a 178-tile Malaysian component and a 30-tile Canadian component are
detached. The control has one split, with Norway and Sweden detached together.
The preferred reference has none. Do not confuse individual component
connectivity with this separate landmass check. Mercator retains exterior
water beside the Baltic states and no exterior-water edge beside Paraguay.

Visually checked both world maps and Mercator details for Europe, Africa,
North America, and Japan/Korea. The layout is joined rather than split into
separate country shapes. Russia, China, and India remain distorted. Neither
new result replaces the preferred reference. The cause of the fresh Equal
Earth flow's repeatability difference remains unconfirmed.

Published images, settings, tile archives, empty lake cells, audits, and
checksums at `results/geography/margin-1-mercator/index.html`. No production
mapping changed. Both jobs have stopped. All 201 tests pass.

## Saved island positions with empty lakes

Applied lake insertion to the saved island-position layout, not to the earlier
mainland layout. The combined map has 55,000 land tiles. All 208 moved island
components retain their exact saved positions. The same 45 lakes have 220
empty cells. These cells do not consume country tiles. Lake positions can
change during local insertion; no global mainland fit was run.

The contact graph matches the saved island layout exactly. Every component
keeps its tile count and remains connected. The source landmass check finds
no split groups. Added an integration check and five regression tests. All
206 tests pass. Visually checked Europe, Africa, New York, and Japan/Korea.

Saved the separate combined baseline and its checks at
`results/geography/islands-lakes-integrated/index.html` (HTTP 200).
No sparse-border cuts or production mapping changes are included.

Next, measure the Kazakhstan constraint against OWID. Keep this combined
baseline unchanged. A larger gap is not a success unless country shapes
improve. Retain dense borders, island positions, and empty lakes.

## Kazakhstan: matched local tests and OWID reference

Added `scope_sparse_borders.py` to restrict the existing population audit without
making a dense border eligible. Selected Kazakhstan's sparse contacts with
China, Russia, and Turkmenistan. Excluded the one-tile Baikonur component.
Turkmenistan's contact was already missing. Only four large components can move;
India is fixed in this first diagnostic.

Ran a 40-round control and an optional-border trial. They produced identical
cells. Then ran an 80-round control and an 80-round trial with two initial border
openings. The openings formed again during refinement. Both runs keep exact
budgets, connected components, fixed islands, and identical empty lake cells.
The seeded trial improves Kazakhstan's outline error from 0.50424 to 0.31057,
against 0.40996 in the control. China changes very little. Russia is worse than
the control, and India cannot change. The seeded trial creates 38 newly empty
enclosed cells, against 19 in the control. Neither trial replaces the baseline.
Both stopped at the round limit; do not claim convergence.

Added `compare_owid_region.py`. It compares largest mainland parts, not distant
islands. OWID has approximately 57 blank cells between Kazakhstan and China,
and 27 between Kazakhstan and Russia. Its shape scores are better for China
and Kazakhstan, but worse for Russia under the unrotated Equal Earth metric.
Thus neither a gap distance nor this outline score alone is an acceptance rule.
The 20-cell local trial allowance is smaller than OWID's separation.

Added `audit_sparse_cut.py`. The full current graph has an above-threshold
contact path from Russia through Azerbaijan, Iran, Afghanistan, Pakistan,
India, Bangladesh, and Myanmar to China. Sparse cuts alone cannot separate
Russia and China into independent connected groups. This does not prevent a
local gap or shape improvement. It means that independent rigid block moves
are the wrong next step under the dense-border constraint.

Next test: coordinated deformation with bounded movement of shape-guide
centroids and movable surrounding countries. Retain dense contacts. Compare
with an equally movable no-cut control. Do not translate distorted rigid shapes
apart, or accept gaps without visible shape gains. This next solver is not yet
implemented.

Visually checked the OWID comparison and both Eurasia trials. Published records
and images at `results/geography/kazakhstan-scoped/index.html`. Raw runs are in
`output/auto-cartogram/kazakhstan-scoped/`. All four runs have stopped. Added
nine tests for scope selection, mainland selection, and graph cuts. All 215
tests pass. No production layout or population mapping changed.

## Trace the Kazakhstan pinch through saved stages

Added `trace_kazakhstan.py` and a gallery at
`results/geography/kazakhstan-origin/index.html`. No new layout was fitted.
The source, continuous fit, partition, and repaired images were checked visually.

The main distortion is already present in the continuous fit. Russia forms a
thin strip above China. Kazakhstan is compressed near its western end. Input
preprocessing changes outline error by only 0.01–0.02 for the four main countries.
The population target shares strongly contract Russia, Kazakhstan, and Mongolia,
while expanding China and India. This explains the pressure, but does not prove
that the specific distorted result is necessary.

The partition then combines the flow footprint and a weight-eight flow-outline
penalty with unwarped population sites. Its fitted Russian site is 113 tiles from
the flow centroid, mostly west; Kazakhstan's site is 29 tiles away, mostly east.
Kazakhstan moves from x=553.76 in the scaled flow to x=600.20 in the partition.
A matched test is needed to separate the centre rule from the other costs.

Kazakhstan is already one connected 134-tile piece at this stage. Fragment repair
then makes 170 Russia–Kazakhstan swaps, all initiated to repair Russia. These move
Kazakhstan about 13 tiles further east, to x=613.53. The repair objective reduces
fragment counts but does not protect the neighbour's geographic position.
Later margin-one, docking, island, and lake stages largely retain this result.

Stop treating this as only a final contact-graph problem. First compare centre
rules on the saved flow and measure pre-repair fragments. Then test a bound on
connected-neighbour displacement during repair. Test larger shape changes and
sparse cuts upstream, with a matched no-cut control. Independent Russia/China
landmasses are not required for shape improvement. These tests are not yet run.

Added three tests for the outline metric. The original flow-input outline is
the reference here, not the later lake guide, so scores differ slightly from
the sparse-border study. All 218 tests pass. The gallery returns HTTP 200.
The baseline and production mapping remain unchanged.

## Coarse Kontur density inside components

Added `kontur_subregion_flow.py`. It clips each represented mainland component
into coarse Equal Earth grid patches and assigns matched Kontur H3-5 centre
population to them. Points outside an outline go to the nearest patch of the
same component. No country-wide redistribution replaces component membership.
Patch target areas sum to the existing component tile-area target.

Compare three density blends on identical patch geometry: uniform component
density, 50% Kontur share, and 90% Kontur share. The remaining area share keeps
targets positive. This is coarse aggregation with a density floor, not Gaussian
smoothing. Try 200-unit and 100-unit grids, nominally 1,274 km and 637 km.
Equal Earth does not preserve distance, so these lengths are only approximate.
The continuous solver starts at 256 cells on its longer axis and can refine.
The density grid and solver grid are different settings.

Initial trials exposed two technical limits. The solver CSV parser rejects
scientific notation. Very small clipped patches also make area fitting unstable.
Write fixed-point targets, do not subdivide components below 16 tiles, and merge
patches smaller than one uniform-target tile into a same-component neighbour.
The first 128-cell solver trials did not converge and are not accepted layouts.

Started matched revised runs with 464 and 858 patches over 189 components.
They cover 7,221,236,218 people in the existing mainland flow scope. Isolated
islands are not part of this fit. No production geometry or mapping changes.
Reference: the cartogram-cpp README and installed CLI help confirm that each
GeoJSON region can have a separate CSV target area:
https://github.com/mgastner/cartogram-cpp .

The solver source confirms a target-area floor of 0.0001 of the total. Added a
second merge rule: use one shared subdivision that clears this floor in every
tested density blend, unless the entire component is smaller. Final grids have
369 and 603 patches. All six final solver runs returned success, each in about
10–16 seconds after preparation. Each retains 189 valid, connected components.
The small numerical overlap share is below 0.0001%; contacts are not certified.

Visually checked all six Eurasia results and the finer 90% global mainland view.
The internal density signal works: western Russia gains area and its eastern
strip becomes thinner. On the finer grid, Russia's outline error improves from
0.896 to 0.612 at 90% Kontur. China worsens from 0.436 to 0.691, India from 0.382
to 0.463, and Kazakhstan from 0.669 to 0.822. The compression is not fixed.
These are outline scores, not population-fidelity scores.

The four large components have area errors below 0.3%. Tiny unsplit components
still receive the solver's minimum-area adjustment. The worst is the one-tile
Western Sahara component, with about 400% relative area error. Therefore these
are diagnostic continuous guides, not exact-budget layouts. No production map
or H3 export changed. No tile repair, islands, or lake insertion was run.

Published images, compressed geometries, requested and processed targets, logs,
input hashes, and scores at `results/geography/kontur-density-flow/index.html`.
Final raw runs: `output/auto-cartogram/kontur-patch-flow-{100,200}-floor/`.
Earlier failed or area-biased trials remain separate. All jobs have stopped.
Added seven tests for budget conservation, positive targets, clipping, and
patch merging. All 225 tests pass; gallery links and artifact hashes pass, and
the gallery returns HTTP 200. Next: combine the coarse density signal with shape constraints
and optional sparse contacts upstream; do not promote the raw outlines.

## Planet tile fit from the coarse 90% Kontur guide

The user selected the coarser 90% result. Added `run_kontur_planet.py` to fit that
saved guide to the original 55,000-tile component budgets. Keep the margin-one
settings, mainland docking, archipelago rules, and empty lake insertion. Use
flow-coordinate centres so that the old unwarped population sites do not undo
the selected guide. This centre rule is an explicit change from the older fit.

Trim only tiny numerical overlaps before the strict flow-input check. Reject
large overlaps or any cleanup that splits a component. Three new tests cover
this guard. All 228 tests pass.

Recompute island positions for the new mainland. Use geometric coast frames;
the old layout's population transport map is not valid for the new mainland.
Do not copy saved island coordinates onto a different world fit. The final lake
count and source-landmass connectivity need fresh checks.

Started `output/auto-cartogram/planet-kontur-coarse90/`. Log:
`/tmp/planet-kontur-coarse90.log`. No strategic cuts are included. First inspect
this full-planet candidate, then use the same settings as the no-cut control
for early-pipeline border-release experiments. No production map is replaced.

The run completed. All 55,000 land tiles and 481 component budgets are exact;
every individual component is connected. The same 45 named lakes retain 220
empty cells and the same per-lake budgets. Independent checks confirm that no
lake cell overlaps land.

The candidate has 73 missing and 48 false administrative contacts, against
63 and 34 in the preferred baseline. One source landmass is split: the 178-tile
Malaysian peninsula is detached from Thailand. Lithuania has no exterior-water
edge, and Paraguay has 16. These are regressions, not strategic cuts. Do not
promote the candidate or replace the H3-MON export.

Visually checked the full world, Eurasia, Europe, Africa, Japan/Korea, Indonesia,
New York, and South America. Japan is not bisected by South Korea. The Kazakhstan
constraint remains. Published the candidate, regional images, tile and lake
archives, settings, and checks at
`results/geography/planet-kontur-coarse90/index.html`.

The next cut experiment must change the early source geometry or deformation
constraints, then carry the optional-contact record through fitting and docking.
A flag cannot separate a shared continuous boundary. Compare against this
recorded no-cut run, and track the coast and mainland regressions separately.
No early-cut run has started. The fit job has stopped. All 228 tests pass.

### Early source cuts: selection and first tests

The user selected the coarse 90% Kontur planet as the current best development
layout. This decision replaces the recommendation above. See `current-best.md`.
Keep the Malaysia, Lithuania, and Paraguay defects open. The tile contact graph
also confirms a false Sweden–Germany contact. Norway does not touch Germany.
Production H3-MON data is unchanged.

Added `cut_flow_source.py`. It opens selected, population-audited source borders
before patch construction and continuous flow. It rejects lost unselected
contacts, invalid components, and area loss above 10%. Fragment removal is off
by default; the wider trials permit at most 0.01% of a component's source area.
Population samples stay in their original component, including samples in the
removed strip. Tile budgets do not change.

Started a fresh no-cut control and two-border and four-border trials. The two
borders are Russia–Kazakhstan and China–Kazakhstan. The four-border trials also
cut Russia–China and Russia–Mongolia. All pass the existing 25 km population
corridor audit. Whole-border statistics do not prove that every segment is sparse.

The four-border 25 km and 50 km preparations failed the unselected-contact guard:
they also remove Russia–North Korea. They were not fitted. The two-border 25 km
and 50 km preparations pass, as does the four-border 5 km preparation. Runs use
all three existing density strengths and the 200-unit grid. Shape scores use
the unchanged geographic outlines, not each trial's cut outlines. Each blend
within a trial uses the same patches; cuts can change patches between trials.
No downstream tile fit has started.

All seven trials completed: two fresh controls and five cut variants, each with
three density blends. All 21 solver runs succeeded. Every trial has 189 mainland
components, 369 patches, and 7,221,236,218 people. The 90% outputs have valid,
connected components. Four-country area errors are below 0.04%; the known
solver floor still inflates some tiny components.

Visually checked the control and cut Eurasia panels, plus the control and 50 km
world panels. Russia still forms a thin strip above China. The two 50 km cuts
reduce Kazakhstan's outline error to 0.743, from 0.797–0.804 in the controls.
Russia stays at 0.729, within the control range of 0.728–0.732. This is not a
useful large-scale shape improvement. The narrowest Russia–Kazakhstan gap in
the 50 km trial is less than 0.00005 target-tile widths. This is a minimum
polygon distance, not an average width along the seam.

Published the images, settings, hashes, geometry archives, and measurements at
`results/geography/strategic-source-cuts/index.html`. See `source-cuts.md` for
commands and limits. No downstream tile fit was justified or started. The next
experiment must permit separate deformation across selected borders, rather
than only insert empty strips into one continuous field. Current best and
production exports remain unchanged. All 234 Python tests pass.

### Independent mainland flow diagnostic

Added `independent_kontur_flow.py`. Each solver call receives only one mainland
component, with the exact saved coarse patch geometry and target strings.
Population and target-area sums are checked. The shared-flow reference is the
saved coarse 90% guide, not a new control. After solving, a uniform scale sets
the component area to its tile budget. This is not a tile fit or world assembly.

The 256-grid Russia, China, India, and Kazakhstan runs completed for uniform
and 90% density. Visually checked all four comparison sheets. The independent
90% shapes are much closer to the geographic outlines. The uniform controls
closely reproduce the original outlines. Canada's extra 90% trial failed with
a non-simple patch boundary; no result from that failed run is used.

Started 512-grid Russia, China, and Canada trials to check resolution sensitivity
and retry Canada. The solver domain changes when neighbours are removed, so
this is not a test of one selected border alone. No assembly is attempted.
Current best, tile budgets, island and lake placement, and production exports
remain unchanged. Four new unit tests pass.

The 512-grid runs completed, including Canada. Russia and China give similar
outline scores at both resolutions. Shared to independent scores are Russia
0.728 to 0.528–0.531, China 0.670 to 0.379–0.382, India 0.444 to 0.128,
Kazakhstan 0.787 to 0.227, and Canada 0.769 to 0.202. All independent uniform
controls have errors below 0.0006. All accepted shapes are valid and connected;
maximum patch area errors are below 0.9%. Fifteen of sixteen solver calls
succeeded. The failed Canada 256-grid call remains in the archive.

Visually checked all four primary comparison sheets, Canada's successful retry,
China's 512-grid comparison, and the enlarged independent Russia shape. Published
`results/geography/independent-kontur-flow/index.html`, with source and output
geometry, solver inputs, logs, hashes, and images. See `independent-flow.md`.

These results justify a regional assembly experiment with independent reference
shapes and selected border constraints. They do not justify replacing the world
layout. All 238 tests pass. All jobs have stopped.

### Regional assembly with released direct contacts

Started a 12-country Eurasian assembly test. Both cases use identical independent
90% Kontur shapes, geographic initial positions, deformation bounds, and penalty
schedules. The cut case removes the Russia–Kazakhstan, China–Kazakhstan,
Russia–China, and Russia–Mongolia contact terms. All four pass the existing
population audit. No cut-specific spring, target gap, or boundary term remains.
General collision, geographic ordering, and position penalties apply in both cases.

The region includes Azerbaijan, Iran, Afghanistan, Pakistan, and India. Thus,
Russia and China still have an indirect route through retained regional borders.
This avoids testing only a region in which the cuts isolate Russia completely.
The eight additional independent neighbour fits all succeeded.

This first implementation is an affine, contact-only prototype. It permits
area-preserving stretch, shear, and translation. Retained contacts use soft
nearest-boundary distance penalties, not matching full-border curves. It does
not yet implement the full boundary constraint proposed above. Exact residual
gaps and overlaps must be reported, not hidden by a successful optimizer return.
Six new unit tests check area preservation, removal of the direct contact term,
no cut-specific gap target, unchanged collision handling, and retained contacts.
Current best and production mappings remain unchanged.

Stopped the first uncached timing run after its first completed stage. Added
bounded caches for unchanged country shapes and pair evaluations. The restarted
first stage has exactly the same objective (2683.466266071664) and iteration
count, but takes 19 seconds instead of 97 seconds. A seventh unit test checks
cache reuse and changing coordinates. Started paired runs with shape weights
0.1 and 1. Each pair has identical settings except for the four removed contacts.

Both initial pairs failed feasibility checks. In the 0.1 pair, residual overlaps
were about 29–32 tile areas and maximum required gaps were about 24–25 tile
widths. Mongolia remained inside China. Intersection area alone is flat under
translation when one polygon is wholly inside another. Added an interior-centre
depth penalty to supply an escape direction, with a unit test for this case.
This general collision term also applies to cut pairs.

Started corrected paired runs, then a version with translations scaled to typical
country size for better numerical conditioning. Also started an SLSQP comparison
with the same corrected objective and initial states. No failed trial is promoted.
These are solver and contact-model tests, not evidence that sparse cuts cannot
work with a full boundary deformation model.

Added an explicit-constraint polish test. Both cases start from the same saved
all-borders pose. Requested limits are 0.05 tile widths per retained gap and
0.001 tile areas of total overlap. An earlier polish launch was stopped before
completion to replace different starting poses with this common start. Neither
interrupted timing or polish launch is published as a completed pair.

Six paired trials completed. None passes even the looser contact-only review
limits (0.1 maximum gap, 0.01 total overlap). The final control has overlap
0.1705 and maximum required gap 2.459. The final cut case has overlap 0.4850 and
maximum required gap 0.580. Its two excessive retained gaps are Azerbaijan–Iran
and Kazakhstan–Uzbekistan. Both final optimizations stopped without success.

The cuts now open real space: Russia–Kazakhstan has a 7.685-tile gap,
China–Kazakhstan 7.047, and Russia–Mongolia 0.687. Russia–China still touches or
slightly overlaps. Removal of a relationship does not require a gap. The cut case
improves Russia's geographic outline score slightly, but worsens China, India,
and Kazakhstan. This is not a successful shape improvement or border fit.

Visually checked the initial failures, corrected intermediate results, and both
published final panels. India narrows and Central Asian shapes remain too thin.
Published all six pairs with explicit failure labels, residuals, geometry, and
input hashes at `results/geography/independent-assembly/index.html`.
See `independent-assembly.md` for commands, limits, and the next model.

The next step needs local boundary deformation and explicit matching along
retained borders, rather than more whole-country affine stretch. Current best
and production exports remain unchanged. All jobs have stopped.

### Full retained borders after the user's rejection of point contacts

The user rejected the contact-only assembly. That approximation left most of
each border unconstrained. Replaced it with `welded_boundary_fit.py`: both
countries now use identical vertex variables along each complete retained
border. Selected cuts receive separate boundary variables. A source-length
check rejects incomplete edge matching, rather than silently leaving a seam.

The new model starts from the saved continuous guide to obtain valid shared
boundary topology. Its preferred shapes are the independent Kontur fits.
It uses local boundary displacement, not whole-country affine transforms.
Contour correspondence uses ordered arclength matching; it is not a new
population transport map. A small within-country elastic term smooths local
movement. No elastic spring crosses a cut.

Added a sparse quadratic-program solver in the experimental geometry environment.
`mesh-requirements.txt` pins OSQP 1.0.5. The Python interface was checked against
https://osqp.org/docs/interfaces/python.html. Areas use penalized slack variables
with sequential linearization. Actual area errors, overlaps, and shared border
lengths are measured. Step limits bound each triangle's deformation gradient.
The mesh is triangulated again after accepted movement. Polygon validity and
inter-country overlap are checked before each accepted step.

Early runs preserved all 23 control borders and all 19 retained cut-case borders,
but shape movement stalled at narrow coastlines. Added self-collision checks
across narrow water gaps, not only collisions between countries. Corrected the
near-edge separation planes so a valid current configuration remains feasible.
Interrupted diagnostic runs are not candidates. Current best is unchanged.
Eight new tests cover full-edge welding, cut independence, incomplete edge
matching, area derivatives, collision feasibility, narrow water gaps, and a
small quadratic-program fit.

### Shared-border checkpoint and contour correspondence checks

Added adaptive step limits and saved a paired eight-iteration regional check in
`output/auto-cartogram/welded-boundary-checkpoint`. All 23 control borders and
all 19 retained cut-case borders have zero gap and positive shared length.
Polygons are valid, overlap is below 0.000001 tile-area units, and maximum
country area error is below 0.2%. However, shape movement is too small to count
as an improvement. A temporary clearance initializer failed and was removed.
There is no prescribed gap across a cut.

Added a three-region test. A-B remains a complete shared edge while a B-C cut
lets C change from a long rectangle toward a square and separate. Visually
checked both synthetic panels and the regional cut panel. The synthetic test
shows that release works. The regional image still has the Kazakhstan pinch
and the narrow Russian strip. It is not a new candidate planet layout.

Published the checks at `results/geography/welded-boundary/index.html`. The old
point-contact gallery now has an explicit rejection notice and a link to these
checks. See `welded-boundary.md` for the method, limits, and repeat commands.

Audited the ordered Kontur patch labels along the source and preferred outlines.
The label cycles agree for Russia (54 runs), China (23), India (16), and
Kazakhstan (four outer runs and one hole run). Added an optional label-based
contour mapper with explicit fallback records for ambiguous label cycles.
This mode is not used in the published pair. It rejects China's sampled target
contour because it intersects itself, including at a finer one-tile sampling
limit. A diagnostic found five crossing edge pairs among 1,355 sampled points.
Thus matching label order alone does not establish valid sampled contours.
Do not remove the validity check to accept this result. The next task is
contour correspondence and sampling with shared refinement on retained edges.

All 261 automatic-cartogram tests pass. The current-best cell file retains
SHA-256 `3f6e042629c1c77ffa251a1f36e7cb40f494c21ca35d9ee84b0ca1e02667cb1e`.
No production layout or population mapping was replaced.

### Contour sampling repair

The rejected mapped contour joined valid points with straight chords that
skipped bends. Added bounded adaptive subdivision at crossing target chords.
Each split source edge receives the same midpoint on both sides. Retained
borders therefore keep identical variables after refinement.

Repeated nearest-point projection during subdivision did not converge. A
coarse source contour also caused projection to jump across narrow bays.
Changed correspondence to project original source vertices only. Initial
samples interpolate their target parameters along each source edge. Further
refinement bisects those fixed parameters instead of projecting again.
A cycle check requires the target parameters to wind exactly once.
Self-intersection checks remain active; unresolved refinement fails closed.

Added regression tests for crossing chords, shared refinement, fixed parameters,
cyclic interpolation, and invalid parameter winding. All 264 tests pass.
The coarse patch-guided run now builds valid target contours after one round
of eight edge splits. Paired regional shape tests are in progress. This is
not yet evidence of a better layout. Current best is unchanged.

### Paired results after the contour repair

Completed the fine pilot, coarse paired test, one-tile simplification test, and
coarse retry test. Output directories are `welded-boundary-refined-parameters`,
`welded-boundary-anchor-coarse`, `welded-boundary-anchor-tile`, and
`welded-boundary-anchor-retry`, under `output/auto-cartogram`.
The early fine pilot used fixed parameters but not the later original-vertex
anchors. Its result is diagnostic only.

The first coarse control accepted 12 steps. The cut case hit the quadratic
solver's iteration limit before movement. Added a bounded retry with a smaller
trust region for this status. Failed solver outputs are never accepted.
A regression test checks that retries leave the current geometry unchanged.

The final coarse pair uses 24 iterations, source simplification 0.3, and maximum
initial edge length six. Both cases need one round of eight edge splits for
the patch-guided target contours. The control accepts 24 steps; maximum area
error is 0.027%. Geographic outline errors change from approximately 0.728 to
0.707 for Russia, 0.670 to 0.661 for China, 0.444 to 0.440 for India, and 0.787
to 0.728 for Kazakhstan. The starting values come from the almost unchanged
cut output, not from independent target shapes.

The cut case accepts only one very small step in eight attempts. Final overlap
is 0.000000501 tile-area units and maximum area error is 0.170%. Subsequent
proposed steps have valid polygons but overlap between countries; they are
rejected. Smaller trust regions alone did not solve this. All 23 control
borders and all 19 retained cut-case borders remain complete shared edges.
The one-tile simplification test also fails to give a useful cut layout, with
cut-case area error 4.62%. It is not a candidate.

Visually checked both coarse panels, both one-tile panels, and the final
published pair. The control has small outline changes, but Russia remains a
thin strip and the Kazakhstan pinch remains. The cut panel is almost unchanged.
The next task is the collision model at released borders and solver convergence,
not another claim that successful contour construction solves the layout.
Single-label rings and ambiguous label cycles still use whole-outline matching.

Published the final pair at `results/geography/contour-refinement/index.html`.
The table now distinguishes accepted steps and solver status from valid final
geometry. Updated `welded-boundary.md` and linked the previous checkpoint.
All 265 tests pass. No fit jobs remain active. Current best and H3-MON exports
are unchanged.

### Actual cut-border collision and signed-clearance repair

Captured a rejected proposal from the coarse cut fit. Russia–Mongolia accounts
for 0.210361 of its 0.211175 tile-area overlap, more than 99%. The current mesh
has only 0.000000501 overlap, within the existing numerical tolerance.
Some sampled points are therefore just inside the neighbour. The old radial
separation vector points inward at those points, but treats their depth as
positive clearance. This is a sign error, not a desired border relationship.

Corrected the direction and the signed clearance for interior points. The saved
proposal violated the old full-mesh constraints by only about 0.00000104 in row
units. It violates the corrected two-country constraints by 0.0560. Added a
compressed Russia–Mongolia fixture from the actual mesh and a regression test.
The recovery check now permits correction of an accepted tolerance-sized overlap
instead of requiring zero movement to remain feasible.

Added `--trace-collisions` to save current geometry and rejected proposals
separately. Added `--countries` for smaller tests with the same inputs and cut
policy. Published and visually checked the close-up at
`results/geography/collision-replay/index.html`. Red marks the rejected overlap;
it is not an accepted map. All retained border variables remain shared.

The signed-clearance fit accepts more steps but still makes little movement.
Its later proposed overlap drops to about 0.00172 tile-area units, but the
accepted steps become small near the numerical overlap limit. A three-country
Russia–Mongolia–China comparison is also running. The sign fix is necessary,
but it is not yet a successful release of the pinch.

### Small real-geometry tests after the collision fix

Completed `welded-signed-recovery` for the 12-country cut case and
`welded-three-country` for Russia, Mongolia, and China. The small cut case keeps
the complete China–Mongolia edge and releases the two Russian borders. At 24
iterations it accepts 23 steps, but overlap stays close to the 0.000001
acceptance limit and shape movement remains small.

Tested an optional 0.0001-tile numerical clearance at nearby non-welded edges.
The default remains zero, and the option rejects values above 0.001 tile units.
This is not a visible map-gap target. The first experiment applied the offset
at coincident corners and produced contradictory constraints. Stopped that run
(`welded-three-country-clearance`) and excluded those endpoint contacts from
the offset. Tests check this small clearance and unchanged welded borders.

The corrected run, `welded-three-country-clearance-corners`, has a 40-iteration
limit. Its control accepts 34 steps. The cut case accepts ten steps in twelve
attempts, then stops at the solver iteration limit. Cut overlap is about
0.000000000011 tile-area units and maximum area error is 0.020%. The full
China–Mongolia border remains shared. These are different iteration budgets
from the signed-only test; do not claim a controlled speed improvement.

Published both pairs at `results/geography/three-country-signed/index.html`
and `results/geography/three-country-collision/index.html`. Visually checked
the final buffered pair. The control changes more than the cut case. Russia
still forms a thin strip. This does not meet the goal of a visible release of
the pinch. The sign error is fixed, but the optimizer and its already-pinched
starting geometry still need work. Do not enlarge gaps to conceal this failure.

All 270 tests pass. Published checksums and links are checked. The production
layout, current-best cells, and H3-MON exports are unchanged. All fit jobs have
stopped. The next test should separate initialization problems from remaining
solver constraints, using the small real-geometry case rather than another
planet run.

### Two-hour early-cut investigation: started 2026-10-16 at 13:32 UTC

The user requested continued work for at least two hours, with a useful release
of the pinch as the goal. The minimum end time is 15:32 UTC. Current best remains
unchanged. This entry records work in progress, not completion of that period.

Added an original-geography start to the shared-border fitter. Patch-labelled
correspondence now uses the original Kontur patch geometry for that start.
Three native-start pilots completed. Native geometry can open an eight-tile
nominal slit in the three-country test, but the quadratic fitter leaves country
area errors of several hundred percent or more. These are not cartograms and
must not be promoted. Large-gap attempts on the already-pinched shared guide
failed the geometry checks; no opening was applied in those runs.

Added an elastic source-opening initializer. It retains the same variables on
all uncut borders and duplicates variables only on audited cuts. The recorded
opening target is nominal, not a measured minimum gap. Full-world checks exposed
a flaw in perimeter-only springs: holes stayed fixed while outer rings moved,
and narrow coasts could fold. Interior triangle edges now move holes with their
country and constrain narrow features. Failed seed attempts remain recorded.

The second experiment opens the original world before population flow. It
simplifies the complete 369-patch coverage, retains every patch label and target,
and transports patches through the source mesh triangles. This tests a much
wider source opening than the previous 1–50 km strips. All 189 source components
are present, so external retained borders are not silently omitted.

Preparation pilots exposed numeric seams between independently transformed
triangle pieces. Added canonical shared-point mapping, local affine coordinates,
and bounded area checks for numeric polygon repair. The full-component and
retained-border checks remain active. Failed preparation outputs are not solver
inputs or candidate maps. The first complete population-flow comparison is
still pending at this checkpoint.

Research: read sections 4.1–4.4 of “Topology-Preserving Line Densification for
Creating Cartograms”, https://arxiv.org/html/2511.08121v1. Its method inserts
vertices where boundaries cross triangulation edges and uses piecewise affine
mapping. This supports transporting whole clipped patch pieces rather than only
moving their original vertices. It does not establish that our cut layout will
improve. Checked the geometry repair API at
https://shapely.readthedocs.io/en/stable/reference/shapely.make_valid.html.

### 14:38 UTC: wide source cuts and gradual area changes

Tested 100, 250, 500, and 1,000 km source cuts before patch construction.
The four-border policy rejects the wider cuts because they remove the retained
Russia–North Korea border. Added a separate research policy for short bypass
borders: at most 50 km long, with at most 500,000 people in the audited corridor.
It selects Russia–North Korea. This border fails the original density rule.
The alternative policy is not approved for production.

The 100, 250, and 500 km alternatives completed both population-flow variants.
All 7,221,236,218 people remain in their original components. Source land is
removed, not population. The 500 km cut removes 45% of Kazakhstan's source area
and 16% of Russia's. This large source change is an explicit diagnostic, not an
acceptable default. The 1,000 km strict trial also removes other unselected
borders and fails before flow. The original contact checks remain active.

Visually checked the 100 and 500 km Eurasia panels. Gaps become visible, but
Russia remains a long strip above China. Kazakhstan becomes thinner. These
results do not give the requested shape recovery. The solver's area floor still
inflates tiny components; a successful process exit is not an exact-area fit.

Started a different test: gradually change the original geographic areas and
contours toward the population targets. The cuts exist before the first step.
Uncut borders retain all their shared vertices. Both three-country and
12-country cases are running, with finer and coarser source contours. A stage
with more than 10% area error stops the sequence. Final reports always measure
against the final population targets, not the intermediate stage targets.

Also tested source openings with all unrelated country vertices fixed. This
removes distant coast failures from the opening calculation. The strict overlap
and triangle checks remain active. A direct boundary transport method replaces
the triangle-piece union method in a separate experiment. Its small tests pass,
but the world identity test still fails at Egypt. Bounded precision repair did
not resolve that failure. No failed transport is used for flow or a tile fit.

All 279 tests pass at this checkpoint. Current best and H3-MON are unchanged.

### 15:00 UTC: separate flow domains show a visible change

The gradual-area fits stop before they reach the population targets. Coarse
three-country and 12-country fits reach 28% and 30% of the sequence. Their final
area errors remain too large. An extra self-contact constraint did not improve
progress. It remains optional and off by default. The full-world opening solve
was stopped after repeated tiny steps at the same Egypt coast defect.

Found a larger structural limit. For independent connected-group flow, the cuts
must split the retained border graph. The four earlier cuts do not do this.
Russia still has routes to China through North Korea and through the Caucasus.
A complete separator is impossible under the original density limits.

Added a separate relaxed-policy test. It permits mean corridor density up to
75 people/km² and segment p90 up to 150, or the earlier short-border alternative.
A minimum cut then selects Russia's borders with Azerbaijan, China, Georgia,
Kazakhstan, Mongolia, and North Korea. Azerbaijan and North Korea fail the
original rule. The new policy is explicit and is not approved for production.
The sum of corridor populations is 6,761,887. This is a graph cost, not a count
of unique affected people; corridors can overlap.

The original 143-component connected land group becomes two flow domains:
46 components in Europe and Russia, and 97 in Asia and Africa. Each domain
retains its complete internal borders. The saved Kontur patches and target rows
are unchanged. No source land is removed. Assembly translates whole domains;
it does not fit each country independently.

At grid 512, all 287 uncut regional contacts remain. The no-cut control has 293.
Russia's outline error falls from 0.7132 to 0.5839; China's from 0.6053 to 0.5249;
India's from 0.4368 to 0.4097. Kazakhstan worsens from 0.7242 to 0.7707.
Grid 256 and 1024 repeats show the same improvement directions. Tiny components
still have area-floor errors. The six-cut guide has small numeric overlaps,
which must pass the existing bounded cleanup before any tile fit.

Visually checked the regional two-domain map and the assembled world guide.
Russia no longer follows the full top edge of China. Europe remains joined
internally. This is a visible partial release, not a complete solution:
Kazakhstan and Mongolia remain thin, and Nordic shapes need work.

Started a 55,000-tile preview with the same island and empty-lake stages as the
current best. All stages receive a separate contact file with only the six cuts
removed. The original contact file and production exports are unchanged.
A second diagnostic tests a complete China–India separation as well. It requires
15 extra cuts under the relaxed rule, so its policy cost is substantially higher.
Do not treat more empty space alone as an improvement.

Published the failed wide-strip comparison at
`results/geography/wide-early-cuts/index.html`. It includes the four completed
flow cases, the rejected cuts, population totals, and area-error warnings.
All 283 tests pass after adding graph-policy and optional self-contact tests.

### 15:27 UTC: three-domain tile results and visual checks

Completed three-domain fits and full 55,000-tile previews. The p90-150 rule
selects 21 cuts. Allowing p90 200 selects 18 cuts with a lower corridor-population
cost: 14,847,167 instead of 23,284,336. The mean-density limit stays 75.
A pilot with mean limit 125 selected the same 18-cut graph; the final run uses
75. Five of the 18 selected borders fail the original mean-20/p90-50 rule.
They are Russia–Azerbaijan, Russia–North Korea, China–Myanmar, Laos–Myanmar,
and Myanmar–Thailand. This policy change remains explicit and unapproved.

The 18-cut tile preview gives the first useful release in this investigation.
Compared with current best, its tile outline errors change as follows:

| Country | Current best | 18 cuts |
| --- | ---: | ---: |
| Russia | 0.5856 | 0.5154 |
| China | 0.5168 | 0.3570 |
| India | 0.4278 | 0.3922 |
| Kazakhstan | 0.3438 | 0.3669 |

All 55,000 tiles and 481 connected components remain. The 45 named lakes occupy
220 empty cells, with no lake cell assigned to a country. All 18 selected cuts
remain open. Against the same retained-contact policy, missing borders decrease
from 65 to 50. False geographic contacts decrease from 48 to 27. The continuous
three-domain guide retains all 275 uncut regional contacts before raster fitting.
This does not make the final tile map topologically exact.

The six-cut preview is less successful than its continuous guide suggests.
Its tile outline scores improve for China but worsen for Russia and Kazakhstan.
This is why both continuous and tile scores are now published. The three-domain
21-cut result also improves China and India but leaves Russia's tile score close
to current best. Solver repeats can vary. One three-domain attempt failed on an
invalid Norway patch; its output was rejected and the full run was repeated.

Visually checked the world previews, Europe, Africa, Japan and Korea, all three
six-cut flow resolutions, the three-domain guides, and the OWID excerpt. OWID
permits a large Russia–China separation but keeps China and India in contact.
Our three-domain method needs more cuts. Britain is too far south, Nordic shapes
remain weak, and Kazakhstan still needs work. Current best is not replaced.

The 21-cut preview exposed an island regression: Japan stayed north-west of its
proper position. The archipelago stage found a source-consistent eastward move
but rejected it because its norm exceeded the old displacement limit. Added an
optional general rule: allow the minimum shift required by source separation,
then limit extra movement. It moved the Japanese group by (159, -40) tiles without
changing island shapes, mainland cells in that stage, tile counts, or retained
contacts. Japan is now east of Korea. There is no country-specific exception.
The 18-cut preview already placed Japan on the correct side of Korea.

Enclosed non-lake water increases from 338 to 587 cells in the 18-cut map.
This is not a phantom-hole count. The two largest regions are beside the Red Sea
countries (192 cells) and the Baltic countries (133 cells). The published audit
lists neighbouring countries for the largest empty regions. Smaller gaps still
need source-water checks.

Published `results/geography/complete-separator/index.html` with the 18-cut map
first, two alternative tile previews, regional images, six flow comparisons,
explicit cut lists, and checked cell downloads. Added `complete-separator.md`
with the main result and reproduction commands. Checked the page in headless
Chromium and checked its HTTP response, local links, and all 59 file hashes.
Nine source records and 25 unique input hashes pass their checks. All 286 tests
pass. Current-best cells retain their original SHA256. All experiment jobs have
stopped. H3-MON exports remain unchanged.

### Final validation

All 288 tests pass. A missing corridor measurement cannot authorize a short
border cut. The planet runner now rejects a custom policy that still requires
one of its recorded cuts, even when all file hashes match. Its run record also
includes the copied component-budget file. Checked the review page at desktop
and narrow widths in headless Chromium. All changes are committed; the two user
PDF files remain untracked and unchanged.

### Return to coarse 90% Kontur: coastal island groups

Kept the current best unchanged. Added `audit_coarse90.py` to check the saved
stages and make labelled New York images. Long Island starts southeast of
Manhattan in the partition. It moves northeast during border fitting. The final
archipelago pass does not group these islands: the nearer mainland coast stops
that grouping. Source centroids alone are not a useful correction here. The
geographic centre of Long Island is slightly north of Manhattan; the nearby
western coast is the important relationship.

Added optional `coastal_groups` to `restore_archipelagos.py`. When the nearest
larger body is mainland, the rule also checks the nearest larger island. It uses
the existing source-gap limit. Defaults do not change. Four tests cover the
new group, the unchanged default, a distant island, and no eligible island.

Ran `refine_coarse90.py` to make
`output/auto-cartogram/coarse90-coastal-groups-lakes-v2/`. The first run completed
the map but failed while drawing a review because Matplotlib was not installed.
Changed the new review code to SVG with the existing renderer, then ran again
in a new directory. The second run completed.

Checked labelled New York images, Europe, Indonesia, and Japan/Korea visually.
Manhattan is now beside the western end of Long Island. The relative centre
vector changes from (4.83, 6.05) to (7.83, -0.95). The island stage keeps
mainland cells fixed. The repeated lake stage changes boundary cells in five
mainland components. All 55,000 tiles retain exact component budgets. All 481
components remain connected. The 45 lakes use 220 empty cells; an independent
check confirms that none overlaps land. Missing and false contacts remain 73
and 48. All 292 tests pass.

The stage audit locates the remaining defects. Malaysia loses its Thailand
contact during tile repair. Lithuania has no exterior-water edge in the initial
partition. Sweden already touches Germany there. Paraguay has 13 exterior-water
edges in the partition and 16 after repair. These defects remain open.

Published the candidate, comparisons, audit, records, and cell downloads at
`results/geography/coarse90-repairs/index.html`. No strategic cuts or H3-MON
changes. Continued mainland experiments are recorded in `coarse90-repairs.md`.
Published `results/geography/coarse90-repairs/mainland-v1/index.html` after
independent tile, contact, and lake-shore checks. This trial has 69 missing and
34 false contacts. It fixes the Malaysia connection, Sweden's Germany contact,
and Lithuania's lost coast. It retains the New York correction. Paraguay's
false coast, the Finland–Norway regression, and other border defects remain.
Do not promote this trial. All 308 tests pass. No experiment jobs remain active.
The current-best cell SHA256 remains
`3f6e042629c1c77ffa251a1f36e7cb40f494c21ca35d9ee84b0ca1e02667cb1e`.

### Further repair trials

Added an optional inland coastal buffer and fixed lake-shore cells to coast
swaps. Added optional true-contact restoration to short rigid translations.
Ran both from `coarse90-lithuania-lakes-v1` with frozen code snapshots.
The buffer gives 67 missing and 34 false borders, but does not repair Paraguay.
The translations give 65 missing and 32 false borders, but increase false coast
access for Ethiopia and KAB. Rejected the translation trial. Neither trial is
promoted. Checked the South America and Africa images, and the Nordic reference.
The wider Nordic local fit is infeasible under its window and reach constraints.
Recorded results and images in `coarse90-repairs/followup-v1/index.html` under
`results/geography`. The next test must allow the Nordic outside boundary to
change. Paraguay needs connected coastal cover during fragment repair.
All 311 tests pass. The current-best hash is unchanged. No trial jobs remain.

### Joint fits with a movable coastline

Added optional empty cells to the local fit. Tile counts remain exact. Explicit
movable labels limit the fit to a group. Lake cells and all shore neighbours
stay fixed. The final flood fill rejects extra inland coast or lost coastal
access. Added source-template costs and an optional perimeter cost. Defaults
keep the old footprint. All 316 tests pass.
The first joint Nordic fits restore Finland–Norway, but visual review shows
thin strips. Neither is approved. Further shape and Paraguay trials are in
progress. The current best and production exports are unchanged.

Completed the joint-fit trials. Source-template fitting first restores the
Nordic border. A second local fit uses squared template distance and perimeter
costs. This gives `coarse90-nordic-expansion-v6`: 68 missing and 34 false borders.
Only the three Nordic components change relative to the mainland repair trial.
All exact counts, component connections, and lake shores pass independent checks.
All lake cells are unchanged. No extra inland coast or lost coastal access occurs.
Checked the world image, Europe, and enlarged Nordic views. Sweden is no longer
rectangular, but Norway has a narrow section and Finland has an awkward lake
extension. Published comparisons at
`results/geography/coarse90-repairs/nordic-v1/index.html`. No promotion.
The two expanded Paraguay trials time out without a feasible incumbent. Its
false coast remains. All 317 tests pass. No trial jobs remain active.

### Lake placement and enclosed-water checks

Tested small interior lake exchanges before the Nordic shape refinement.
The exchange moves empty water, not extra land tiles. It preserves lake shape,
component budgets, country borders, and other lake shores. Shared-shore lakes
cannot move with this method. Two Saimaa positions give valid local fits and
remove Finland's long lake extension. They do not establish correct source
placement. Checked enlarged Nordic images for both positions.
Added optional sea flow to the local model. Non-lake empty cells must connect
to exterior water. A final flood fill also checks for newly enclosed water.
This tests the unnamed holes found between Norway and Sweden and near Åland.
All 325 tests pass. The sea-flow trial is in progress. No current-best change.

Completed `coarse90-nordic-sea-v1`. The local solver reaches optimality. It removes
three unnamed enclosed-water cells relative to the previous Nordic trial.
Independent global checks find no new enclosed-water cells, extra inland coast,
or lost coastal access. Only the three Nordic components and Saimaa change.
All lake counts and shore checks pass. Borders remain at 68 missing and 34 false.
Checked the final enlarged Nordic image and Europe. Finland's lake extension is
removed. Norway's narrow section and the missing Russian borders remain.
Published `results/geography/coarse90-repairs/nordic-lakes-v1/index.html` with
before-and-after images, alternate lake placement, run records, and downloads.
The lake move is a sensitivity test, not a source-verified geographic fit.
Do not apply the unnamed-water rule globally without source-water checks.
A further control keeps Saimaa fixed and adds sea connectivity directly to
the previous Nordic fit. It removes the local unnamed holes but retains the
lake extension and a long water channel beside Norway. Checked its enlarged
image and added it to the comparison page. The control reaches local optimality.
Also checked the review page in headless Chromium.
No current-best or H3-MON change. All 325 tests pass. No trial jobs remain.

### Paraguay: three-component exchange

Found a valid inland seed without changing the land footprint. Paraguay moves
three cells east into Brazil. One old boundary cell is retained to keep Bolivia.
Argentina takes the vacated coastal strip. It then gives 29 original boundary
cells to Brazil. All three budgets balance. This changes 87 labels, removes all
16 Paraguay sea edges, and restores Argentina–Bolivia. No true border is lost
and no false pair is added. The rule has no country-specific branch.
The seed has a narrow Argentine extension. It is not a production shape.
A first local refinement passes all coast checks. A stronger-cost trial is
rejected because another inland coast grows. Added a conservative occupancy
constraint beside fixed inland neighbours. A larger refinement is in progress.
Added explicit `--refine` mode so valid coast access does not skip shape fitting.
Two initial refinement commands did skip the fit; their empty target records
are not results. The actual refinements use the new flag and frozen code.
All 331 tests pass. The current best and H3-MON exports are unchanged.

Completed the larger refinement and a thin-cell cost. The final candidate is
`coarse90-paraguay-water-v1`. Paraguay has zero sea edges and all three true
neighbours. Argentina–Bolivia is added. Only the three main South American
components change. No true border is lost and no false pair is added.
Argentina's thin-cell count falls from 26 in the seed to 13 after refinement,
but its northern extension remains. Its perimeter is 192, versus 158 before
this repair. The world has 67 missing and 34 false borders. Bolivia's existing
25 sea edges do not increase.
One larger fit filled an uncertain enclosed-water cell. A water-pinned fit
then timed out without an incumbent. Added a single-country vacancy restoration
that restores all enclosed reference water and shore labels without changing
any budget. Only two endpoint cells change. The final candidate retains all
named and unrecorded enclosed water. It has no new country or island axis-order
errors. The intermediate Argentine axis-order error is absent in the final fit.
Checked the world image, South America, and enlarged stage comparisons.
Published `results/geography/coarse90-repairs/paraguay-v1/index.html` with data,
checks, stage records, and rejected-trial records. No promotion: Argentina's
shape and coast orientation still need review. All 337 tests pass. No trial
jobs remain. The current best and H3-MON exports are unchanged.
