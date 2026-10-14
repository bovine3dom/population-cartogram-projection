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
