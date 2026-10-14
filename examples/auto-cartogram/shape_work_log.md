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
