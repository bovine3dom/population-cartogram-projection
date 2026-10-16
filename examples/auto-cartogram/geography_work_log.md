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
