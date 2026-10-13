# Automatic layout work log

## Goal and work budget

Start: 2026-10-13 20:45 UTC. Requested work budget: eight hours, ending at
2026-10-14 04:45 UTC. Record actual work and completed runs below. Do not treat
this budget as evidence that a job ran for eight hours.

Produce headless layout experiments and review images. Start with Indonesia,
then generate world layouts at several tile budgets. Keep production targets
and the transport solver unchanged. Commit code, checks, and measured results
in separate checkpoints. Keep downloaded tools and large intermediate files
under ignored `output/auto-cartogram/`.

## Plan

1. Build pinned GridMapPipeline and GeometryCore revisions. Test the headless
   cartogram path, tile export, and failure handling.
2. Generate Indonesia layouts from component populations. Record zero-budget
   islands, grouping rules, contact errors, and differences between resolutions.
3. Prepare global component populations. Record missing country codes,
   overlapping membership, antimeridian parts, and boundary uncertainty.
4. Generate whole-world previews at several resolutions. Check tile ownership,
   counts, connectivity, and actual contacts before describing a result as valid.
5. Save PNG/SVG previews, small result tables, reproducible commands, and a final
   review guide. State unresolved limits explicitly.

## 20:45 UTC — environment and upstream inspection

- Current audit checkpoint: `cbb6c8b`. The two supplied PDFs remain untracked.
- Available memory: about 53 GiB. Available worktree disk space: about 126 GiB.
- Java, `javac`, Ant, and Maven are not on PATH. Julia and headless SVG rendering
  are available.
- Cloned upstream sources into the ignored vendor directory. Pinned
  GridMapPipeline at `f1c18c0a938bd526e42d531e3728a85f3f0a0305` and GeometryCore
  at `c4f7faa617be73243d658bf8cd671aa6482ab950`.
- Next: inspect build dependencies and install a local, checksum-verified JDK.

## 20:48–21:06 UTC — first layouts and world membership

- Built a headless Java adapter with a local, checksum-verified JDK 21.
- Generated two Indonesia previews at 1,894 tiles. Both have exact counts,
  unique cells, connected regions, and no represented-contact errors.
- Upstream placement puts major islands on the wrong side of Java. Added a
  separate experimental placement rule that uses source bearings.
- Stopped our native global H3-fill job after more than ten minutes. It was
  still on mainland Australia. No partial result was published.
- Decoded all source H3 centres, then assigned them with a Shapely spatial
  index. The spatial join took 25.18 seconds. It matched 32,668,501 cells and
  7,954,677,990 people. It left 289,198 cells and 77,246,034 people unmatched.
  There were no ambiguous matches. The Antarctica seam polygon was skipped.
- Checked Indonesia against the earlier native H3 extraction: all 832,166
  source IDs and their population values match exactly.
- Numeric country codes in Natural Earth are not safe keys. Some codes are
  missing or shared by different entities. Use named source entity IDs.

## 21:08–21:29 UTC — world graph failures and checks

- The first 10,000-tile world graph failed during triangulation. A planar
  straight-line drawing alone did not fix it. Faces around cut vertices had
  repeated vertices, which the upstream convex decomposition could not handle.
- Added temporary sea nodes to make connected graphs biconnected. These nodes
  do not add real land borders and do not carry population.
- Assertions then exposed an inverted guide-size check and a hole-forming local
  move. Fixed copies of upstream sources; original checkouts remain unchanged.
- An independent random-grid test rejected the first connectivity fix. Added
  a four-neighbour check for both land and sea. The test now checks 13,725
  candidate moves; all 8,224 accepted moves preserve connectivity and no holes.
- Restarted the world fit with assertions enabled. Its result is still pending.
- Tests pass: 27 Julia checks and six Python/Java tests. These include repeated
  deterministic placement, invalid inputs, shared borders, and the move oracle.
- No production map or transport code has changed.
