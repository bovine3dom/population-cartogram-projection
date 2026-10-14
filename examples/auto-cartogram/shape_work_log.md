# Shape-first cartogram work log

## Work window

Start: 2026-10-14 05:50 UTC. Requested budget: 14 hours.
End: 2026-10-14 19:50 UTC. Record completed work, not planned results.
Starting checkpoint: `d332714`. Production code and targets stay unchanged.

## Goal

Keep the useful island separation from the first experiments. Remove artificial
thin connections. Use the reviewed Tutte fit as a comparison, not an approved
map. Prefer shape transformation and distortion to paths that force contacts.
Inspect the resulting images at world and regional scales.

## Plan

1. Audit thin regions and their contact constraints. Check whether distant
   territories are linked incorrectly. Separate real land borders from country
   membership and from population grouping.
2. Test continuous geographic deformation, then convert the deformed shapes to
   tiles. Compare it with shape-based improvement of the Tutte layout.
3. Keep component identity, mass, tile budgets, connectivity, and position checks.
   Do not introduce a path simply to satisfy a border constraint.
4. Compare the world at several resolutions. Inspect Europe, Africa, Asia,
   the Americas, and archipelagos. Save rejected examples as well as improvements.
5. Commit checkpoints, record failures, and finish with a short review guide.

## 05:50–05:55 UTC — initial inspection

- The existing contact builder uses shared polygon segments, not shared country
  IDs. Small-island grouping changes population budgets, not contact edges.
  The overseas-territory hypothesis needs a measured audit before acceptance.
- The current flow-based cartogram implementation is `cartogram-cpp`, pinned at
  `9200b14b983581b78992dd6944cceedf384bb02c`. The older C implementation directs
  users to this maintained version. It transforms geometry rather than drawing
  paths between country labels.
- Its license file is AGPL-3.0. The readme also has inconsistent license and DOI
  text; do not use that text as a license clearance. Keep the experiment in an
  ignored vendor directory and cite the 2018 paper with its correct DOI.
- Started an isolated build. The documented Conan 2.16.1 does not recognize the
  installed GCC 16. Switched the isolated tool environment to Conan 2.33.0 and
  kept its cache inside `output/`. No production dependency files changed.

## 05:55–06:26 UTC — diagnosis and first deformation tests

- All 348 required contacts at the 55,000-tile resolution have a shared source
  border. None joins two components merely because they have the same country
  ID. Of these contacts, 26 involve a secondary population component. This does
  not mean that all 26 are overseas borders.
- The Tutte fit has substantial thin detail on mainlands. South Sudan,
  Kazakhstan, Honduras, Bolivia, and the Netherlands are examples. Island
  grouping is not the main cause of these strips. Hard border constraints and
  the layout fitting process remain problems.
- Built the pinned C++ flow implementation without source changes. Its six unit
  tests pass. The 55,000-budget world run took about 9.4 seconds. An independent
  check found no overlaps, no missing land contacts, and all 19 input holes.
- Rejected this first continuous-flow image on visual grounds. Canada, Russia,
  Australia, and much of the Americas become long thin shapes. The method does
  not add connector paths, but that alone does not give a useful map.
- The C++ implementation also raises some small area targets. The largest error
  against our original target is 450%, despite its reported convergence. Keep
  original target checks outside the generator.
- Added a local deformation experiment that starts with the reviewed Tutte fit.
  It exchanges boundary cells to reduce perimeter and geographic shape error.
  Borders are soft costs, not required paths. Component counts stay at their
  initial values; this does not yet correct the Tutte count errors. One-cell
  regions do not move. Seven focused shape tests pass.
- Started five 55,000-budget trials with different shape, perimeter, and false
  contact costs. Images and contact losses still need review.

## 06:26–06:54 UTC — count correction and shape exchanges

- Pairwise exchanges reduce small edge detail but leave many long detours.
  Added balanced exchanges around cycles of regions. These are transfers of
  cell ownership, not paths drawn to preserve borders.
- Added a separate budget fit. It corrects all 2,011 absolute component count
  errors in the 55,000-budget Tutte fit after 133 transfer rounds. The resulting
  map has exactly 55,000 tiles. Shape improvement then preserves these counts.
- Visually reviewed the cycle result. Europe has fewer thin strips, but the map
  still has poor country order and long detours near Vietnam and Nepal. It has
  115 missing contacts and 166 false contacts. Do not approve it for production.
- The opening-loss diagnostic falls from 11.98% to 3.73% for regions with at
  least 25 tiles. Natural coast detail is part of this measure.
- Found a local-move restriction: checking each temporary state can reject a
  useful exchange whose final state has valid topology. Added atomic checks of
  complete exchanges. A test covers removal of a long detour and rollback.
- The first atomic 55,000-tile image still has the Vietnam detour. A wider
  candidate search is running. Also started source-guided whole-region growth
  within available space. This can replace a detour longer than one cell.
  It never requests a new land border and accepts only an energy decrease.
- Started 10,000- and 110,000-budget count-fit and atomic trials. The 10,000
  trial has finished; its image still needs detailed review. The 110,000 trial
  is still fitting counts.
- Tested intact-shape placement at geographic, Tutte, and flow centres. Shapes
  look better, but greedy placement can put countries in the wrong order.
  An FFT collision search matches the original exhaustive search in 100 tests.
- World-mode continuous flow failed during densification of a Norwegian
  component. Disabling simplification let it finish, but the independent
  geometry check rejected a Canadian component. Neither is accepted.
- Added a reproducible optional C++ bootstrap. It rebuilt the pinned checkout
  and passed all six upstream unit tests. The AGPL dependency stays separate.
- Twelve focused Python tests pass. Another 100 randomized cycle and count-fit
  cases passed count, connectivity, hole, and energy checks. Saved the first
  diagnostic tables, rejected flow image, and boundary-cycle comparisons.
  The new review guide is `shape-first.md`.

## 06:55–06:58 UTC — regrowth cost correction

- The full-map energy guard stopped one regrowth trial. The local region cost
  omitted the neighbouring country's coast when a contact was removed. Fixed
  the local cost by measuring it against the map with that region removed.
- Stopped the other two regrowth trials from this build. No result from that
  build is published. Added a direct contact-removal regression and 30 random
  local-versus-global energy checks. All 13 focused tests pass.
- The 10,000-tile atomic result has exact counts, but its continent positions
  are poor. Its starting layout already had that problem. Shape smoothing
  alone cannot correct it.

## 06:59–07:04 UTC — position model

- Added an experimental position model for intact tile shapes. Geographic
  springs retain approximate relative positions. Convex-hull repulsion moves
  overlapping shapes apart. The final integer placement prevents cell overlap.
  Springs are not rendered, and no border contact is required.
- This tests simultaneous displacement rather than the earlier largest-first
  placement. It does not yet allow affine shape distortion. Convex hulls can
  leave too much space around concave coastlines.
- Checked the objective gradient against finite differences and tested a
  two-region collision. All 14 focused tests pass. World trials are next.
- The 55,000-tile count-fit reproduction has finished. Its exported cells match
  the earlier run byte for byte. The corrected regrowth trials with guide costs
  1 and 4 have also finished; their images still need review.

## 10:52–11:05 UTC — review resumed

- Reviewed completed background runs after the user asked to continue. The
  110,000-tile count fit took 36 minutes; its atomic stage took 49 minutes.
  The wider 55,000-tile candidate search took 64 minutes. These are measured
  compute times, not a claim of continuous manual review during the interval.
- All three resolutions now have an exact-count deformation result. The
  110,000-tile image still has bad country order in Asia and block-like large
  countries. Exact counts alone do not make this a usable world map.
- Source-guided regrowth removes the long Vietnam detour at 55,000 tiles.
  However, weak outline costs turn some countries into blocks. The stronger
  outline trial retains more of Japan's and Australia's shapes. Neither fixes
  the starting country positions.
- The intact-shape displacement trials preserve outlines, but a convex hull
  fills coastal bays. This can push Bangladesh out of the space beside India.
  Added collision tests on convex pieces instead. Added soft anchors at real
  source border points instead of hull support points. Neither adds map paths.
- Sixteen focused tests pass, including a concave bay, finite-difference
  gradient checks, and rejection of an anchor without a shared source border.
  The next world runs will test this position model.

## 11:05–11:13 UTC — collision and outline checks

- The concave-piece trial still fails visually. Some small countries remain
  inside large countries in the continuous fit. Integer placement then moves
  them a long distance. Nepal moves about 75 tiles in this final step.
  Internal edges between convex pieces give the collision cost local minima.
- Added a collision cost for each complete tile silhouette. It uses signed
  distances and cached raster correlations. Tests compare the cached cost with
  direct distance samples and check its gradient. A coastal bay stays open.
- Added optional placement with no false contacts. It adds a one-cell gap only
  beside a component that has no source border with the new component. It
  does not require a missing border and cannot add a connector path.
- Added source-outline intersection-over-union checks after translation and
  uniform scale. The area-weighted score is 0.562 for the original Tutte fit,
  0.621 after cycle fitting, 0.660 for stronger regrowth, and 0.933 for intact
  shapes. This exposes the loss of outline detail that a thin-strip score alone
  can hide. The score includes raster and source-hole differences.
- Nineteen focused tests pass, including file-based raster displacement.
  Next: compare the new collision model from geographic centres and from an
  existing non-overlapping geographic layout.

## 11:13–11:25 UTC — silhouette results and regional views

- The first full-silhouette run has exact 55,000-tile counts and no false
  contacts. It retains 102 of 348 land contacts without connector paths.
  Its country outlines are intact. Visual review still finds position problems
  in Southeast Asia, but Nepal no longer jumps to Europe.
- Starting from the separate geographic layout gives a more spread-out map.
  A very strong collision cost can stop before enough geographic movement has
  occurred. Added a smooth collision interpolant to test this limitation.
- Added regional review images. They crop the world layout without moving
  components. Selection uses source component bounds, so overseas territories
  are not pulled into the crop for their mainland country. Labels use a fixed
  screen size in the regional view.
- Added optional compression of long non-border spring distances. This is a
  position experiment, not a classification of ocean or land. It can reduce
  empty space without making a path or changing tile budgets.
- The faster placement path produces the same baseline cells as exhaustive
  placement in the file-based test. Twenty focused tests pass. This will also
  support a larger 500,000-tile world preview.

## 11:25–11:31 UTC — bounded distortion

- Added a bounded deformation mode after intact-shape placement. It permits
  small source-outline changes and gives real shared borders a soft preference.
  It never requires a contact. False contacts are rejected.
- New cells must stay within a buffer of the source outline. The default width
  is 10% of the square root of the component's tile count, with a two-tile
  minimum. Initial cells remain allowed. This avoids a request for a distant
  border becoming a long new connector.
- Twenty-one focused tests pass, including forbidden false contacts, the
  outline buffer, and an exact-count file-based run. World trials are next.
- Prepared the 500,000-tile input. It has 888 represented components in 250
  countries. Grouped island population falls to 1,865,414 people. The source
  still has 77,246,034 unmatched people. This resolution has 20 source holes
  that the tile representation omits. Template generation is running.

## 11:31–11:45 UTC — position checks and provenance

- Visually reviewed the bounded trials. They still remove too much outline
  detail, and they do not improve the border count enough. Keep intact-shape
  placement as the main comparison. Do not select a result only because its
  perimeter is smaller.
- Compression of long non-border distances makes the world easier to inspect.
  The 55,000-tile smooth trial has exact counts, no false contacts, and 84 of
  348 source contacts. Geographic order in Southeast Asia still needs work.
- Added a soft geographic-order cost. It checks the main components of
  countries with at least 10 million people and components of the same country.
  It skips longitude-seam pairs and near ties. It cannot draw a path or alter
  a tile budget. Tests check its gradient and the seam exclusion.
- Added an independent check that every component is an integer translation
  of its input template. This distinguishes intact placement from deformation
  and detects an added or moved cell within a shape.
- The existing Python and Julia test suites pass, including the 108 production
  CPU assertions. The current focused shape suite has 22 passing tests.
- Found a provenance weakness: the position runner hashed source files after
  the solve. New runs capture hashes before the solve. The active 110,000- and
  500,000-tile runs loaded runner revision `73c5f06`. Saved its unchanged source
  before the new edit, with SHA-256 `d5585e4c300ae7d33ad0a0b7ae86839f60308298ca7c24ee74f34fece2a009ab`.
  Their late source-hash fields will need this documented correction after
  completion. No cell data will change.

## 11:45–12:03 UTC — checked image bundles

- Added a static HTML gallery. A plain file server can display it without
  Markdown support. Each bundle includes compressed cells and templates,
  independent checks, file hashes, and regional images.
- All 23 focused tests pass. The file-based test renders images without a
  display, restores compressed cells, and rejects a changed bundle file.
- Reviewed the 55,000-tile direction-cost trials at weights 1, 5, and 20.
  Weight 5 is the next comparison candidate, not an approved layout. It has
  exact counts, no false borders, and 89 of 348 source borders.
- Reviewed its Indonesia and South Asia details. No connector paths were
  added. Positions still need work: Singapore is north of peninsular Malaysia,
  and Sri Lanka is too far north. Large gaps remain in North America.
  These defects must stay visible in the review, not be hidden by the scores.
- Started weight-5 trials at 10,000, 110,000, and 500,000 tiles. The earlier
  500,000-tile trial is also still running. Production files are unchanged.
- Corrected the completed 110,000-tile trial's late runner hash with the saved
  source record. Its cell data did not change.

## 12:03–12:09 UTC — coast-based position targets

- Reviewed all six regional images for the saved 55,000-tile candidate. South
  America keeps recognizable shapes and broad order. Europe has clear defects:
  Ireland is too far south, and Norway is east of Sweden. These are position
  failures, even though the shape and count checks pass.
- Added an optional position target for non-border neighbours. It uses nearest
  source coast points, scales the offsets within each component, and compresses
  only the intervening gap. A large mainland can thus move an island beyond its
  enlarged coast instead of leaving the island near its old centre.
- This target changes only soft position preferences. It adds no contact,
  connector path, or tile. Real border targets are unchanged.
- All 24 focused tests pass. A new test checks an island south of an enlarged
  mainland and verifies that required border targets remain unchanged.
- Started 10,000- and 55,000-tile coast-target trials. Their visual quality is
  not yet assessed. The other resolution trials continue.

## 12:09–12:16 UTC — coarse review and coast-target correction

- Saved and visually reviewed the 10,000-tile direction-cost candidate. It has
  exact counts and no false borders, but Southeast Asia has worse position
  errors than the 55,000-tile candidate. It is a resolution comparison, not an
  improvement over that candidate.
- The first coast-target image had excessive empty space. Investigation found
  a unit mismatch: the flow projection helper uses a radius of 1000, while the
  layout initializer uses a radius of 1. Corrected the gap units and added a
  regression check. The rejected image remains in ignored output.
- Source anchors can also fall beyond a very small raster template. Anchors
  now use the nearest point on the actual template cells. This changes the
  position target, not the tile shape.
- Stopped only the identified, unfinished 55,000-tile coast trial with the unit
  error. Started new trials in separate output directories. All 24 focused
  tests pass, including gap units and the one-cell anchor bound.

## 12:16–12:21 UTC — exact-translation position refinement

- Saved the 110,000-tile candidate and added it to the static gallery. It has
  585 represented components, exact counts, no false borders, and 95 of 353
  source contacts. Visual review still finds poor positions around Afghanistan
  and Sri Lanka. More tiles alone do not solve these defects.
- The corrected coarse coast-target trial does not fix the main position
  errors. The continuous solver can stop with components in poor local positions.
- Added a separate refinement that moves one intact component at a time. It
  solves the conditional position cost, proposes a collision-free integer
  translation, and accepts it only if total position energy decreases. It also
  checks short moves. No false borders or connector paths are permitted.
- All 25 focused tests pass. Tests compare conditional and full energy changes,
  check exact translations and forbidden contacts, and run the file pipeline.
- The first coarse refinement retains 117 of 341 source contacts, up from 70.
  Visual review shows Sri Lanka farther south, but Vietnam and Cambodia still
  have poor positions. Lower energy is not sufficient for map approval.
- The 55,000-tile refinement and both 500,000-tile position trials continue.

## 12:21–12:34 UTC — four resolutions and local direction checks

- All eight Python and Julia test commands pass again. Saved their logs, source
  hashes, and timings under `output/auto-cartogram/shape-jobs/validation-1222`.
  The focused suite had 25 tests at this checkpoint. Production files remain
  unchanged since `cbb6c8b`.
- Completed the 500,000-tile smooth trial. Corrected its late runner hash from
  the saved source record, without changing cells. Its review bundle includes
  this correction. The gallery now has four resolutions and six regional
  details per resolution. Position settings differ between trials.
- Visually reviewed the large world, Indonesia, and Europe. The extra coast
  detail is useful, but Sri Lanka is near Malaysia and Sumatra lies in a bay of
  the enlarged India shape. These are not acceptable geographic positions.
- Global direction constraints can create avoidable gaps. For example, they
  ask Canada to remain north of Germany as well as north of the United States.
  Added an optional local distance limit. Local checks include small countries
  with lower weights. They do not connect islands or change counts.
- All 26 focused tests pass. The added test checks local small-country pairs,
  excludes a distant country, and checks the gradient. Started local-order
  trials with two strengths for non-border position preferences.
- The 55,000-tile integer refinement retains 114 of 348 borders. Sri Lanka
  moves south but to the wrong side of India. Do not select it on border count.
- The large Europe detail also shows narrow white cuts inside Great Britain.
  A source-outline overlay confirms that some cuts are template artifacts,
  not source coast features. Template cleanup needs a separate check before
  calling these outlines satisfactory.

## 12:34–12:48 UTC — template cuts and cleaned trials

- Added count-preserving template cleanup. It fills narrow interior cuts and
  removes boundary cells to restore the budget. A change must improve source
  intersection and perimeter, while preserving connectivity and no tile holes.
  Components are processed separately and are not joined.
- Visually reviewed Great Britain before and after cleanup. The white cuts are
  removed while the coast remains recognizable. Its count stays at 4,064 tiles.
  An independent full-source outline check improves from 0.9298 to 0.9457.
- Cleaned 24, 66, 74, and 120 components at the four resolutions. Independent
  tile-weighted outline scores improve at each resolution. Saved the audit
  tables and the Great Britain comparison under `results/shape-first/template-cleanup`.
- All 27 focused tests pass. Added cleanup count, topology, intersection, and
  perimeter checks, plus a headless before/after image test. Review bundles can
  now include the template-cleanup record.
- Started cleaned-template placement at all four resolutions, followed by
  exact-translation refinement. These are new output directories. The gallery
  still shows the earlier templates until the new layouts are checked.
- Local direction checks reduce the North American gaps, but the 35-degree
  neighbourhood still gives Sri Lanka poor positions. Started two smaller
  neighbourhood trials at 55,000 tiles. A soft geographic-order score can
  conflict with the new sizes of distant countries; it must not become another
  hard constraint that forces unnatural shapes or positions.

## 12:48–12:55 UTC — population-weighted position preferences

- Inspected Sri Lanka's source-neighbour graph. Its links include the Indian
  mainland and several one- or two-tile islands. Equal spring weights let tiny
  neighbours exert the same position preference as the mainland.
- Added optional population weights. Spring weights use the square root of the
  smaller component population divided by mean country population, with bounds.
  Same-country direction weights also decrease for tiny components. This does
  not remove any component, population, tile, or border record.
- All 28 focused tests pass. The new test checks that tiny-island forces decrease
  and that spring weights are unchanged by a uniform rescaling of population.
  The file test also covers weighted placement and its integer refinement.
- Started two weighted 55,000-tile trials. The smaller local-neighbourhood trials
  are complete; refinement is running. Their first images still place Sri Lanka
  too far north, so neither is selected yet.
