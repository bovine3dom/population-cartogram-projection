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

## 21:30–21:36 UTC — valid guides and first world images

- Added a separate geography-first baseline. It preserves tile counts and
  connected shapes, but removes all land borders. Its images state this limit.
- The baseline rejected invalid simplified outlines. The 10,000-tile input had
  43 self-intersections from coastline simplification. Added an outline check
  that restores original projected rings in these cases. The 55,000- and
  110,000-tile inputs each need 44 such changes.
- Stopped the two Java runs that used unchecked guides. Started new runs with
  checked guides. Do not use the earlier Indonesia or world attempts as final
  evidence of geometry validity.
- The first checked world baseline completed at 10,000 tiles in 2.53 seconds.
  It has 349 shapes and 250 Natural Earth entity IDs. The review image has
  geographic structure, but all 352 represented land contacts are absent.
- Generated the 55,000-tile baseline and started the 110,000-tile baseline.
  All images include the 77,246,034 unmatched source people in their captions.
- Nearest-polygon diagnostics place 58,590,218 unmatched people within 0.01
  degree of a source polygon. Another 1,097,467 are more than 0.1 degree away.
  These angular distances are not physical distances or proof of ownership.
- Added optional bounded optimizer settings. Completion markers record them.
  Assertions remain enabled. A thread sample confirms that full connectivity
  assertions have a substantial cost in the global Java fit.
- Added tests for polygon holes, ambiguous membership, batch boundaries,
  planar augmentation, guide fallback, and separate-shape growth.

## 21:40 UTC — saved review gallery

- Saved world PNGs at 10,000, 55,000, and 110,000 tiles, with checks and source
  grouping tables. All three geography-first baselines have exact requested
  counts, unique cells, connected regions, and no holes. They retain no land
  borders and are not production candidates.
- Grouped population falls from 27,896,450 to 6,099,545 across these resolutions.
  All layouts exclude the same 77,246,034 unmatched source people.
- Saved a checked Indonesia Java layout at 1,894 tiles. Counts and structural
  checks pass. The same-country axis-order diagnostic still finds 426 errors
  in 2,323 comparisons; compact placement is not geographic accuracy.
- Added country area-error tables. A one-tile country minimum can greatly
  exaggerate tiny source populations, even when requested counts match exactly.
- Found that NetworkX can make different choices across Python hash seeds.
  Future CLI runs require `PYTHONHASHSEED=0`. Save the actual embedding files
  for the earlier pending runs, which did not pin this seed.
- Global Java fits remain in progress. No global topology-preserving success
  has been established. The gallery states this limit.

## 21:41–21:52 UTC — transport by declared group

- Added a CPU wrapper around the existing transport solver. It solves each
  declared island group separately and checks mass and tile-budget consistency.
  Production solver code is unchanged.
- Added an unrestricted pooled comparison. An exploratory H3-3 run uses 619
  source aggregates and 1,894 targets. Grouped transport has zero cross-group
  mass and retains about 99.62% of source population. The pooled run moves about
  214 million people across these group labels. This coarse result is not a
  measurement of the old OWID map or native H3-8 transport.
- Added source-retention and per-target balance diagnostics. Stop and restart
  the early native-cell run with this fixed diagnostic version. Its incomplete
  attempt is not published. Capture the script hash when the module loads,
  rather than after a long run during which the file could change.
- Tests pass: 20 transport checks and seven Python/Java layout tests. The
  transport checks include analytical cases, a real CPU solve, invalid inputs,
  mass checks, and atomic output.
- Started a Java performance comparison with only the expensive per-move
  region assertions disabled. Other assertions remain enabled. Its completion
  marker records this setting. Final independent validation is still required.
  The all-assertions runs remain separate reference experiments.

## 21:54–21:58 UTC — bounded world fits and native transport

- Added an optional round limit to the upstream reshape loop. It returns the
  best state reached in each stage. The default remains unlimited. The adapter
  validates and records the setting. Use the limit for previews, not as proof
  of convergence or exact counts.
- Started a 110,000-tile world fit with 50 rounds per stage and a pinned Python
  hash seed. Copied the compiled classes before the run to keep its build fixed.
  One guide-offset trial reports a numeric intersection failure; the job has
  not yet failed or completed.
- The 10,000-tile performance run reached finalization after about 13 minutes.
  It reports remaining gaps. Wait for the exported cells and independent checks
  before drawing a conclusion about region holes or topology.
- Started fixed-version grouped and pooled H3-3/H3-5 transport comparisons.
  Restarted native H3-8 grouped transport with a five-hour timeout and two CPU
  threads. This remains a pending result, not a completed validation.
- The fixed H3-3 runs reproduce the earlier cross-group results. Their maximum
  per-target population errors are 12.76% grouped and 11.04% pooled. Zero
  cross-group movement alone is therefore not a sufficient acceptance test.

## 21:59 UTC — visual check catches a coordinate error

- The transport diagnostic image showed north/south inversion. Inspection of
  `src/spatial.jl` confirms that the public solver expects target y to increase
  downwards. The new mosaic export uses north-up grid coordinates.
- Corrected the wrapper: negate target y before the solver call, then restore
  it in the mapping export. Added a north/south regression test.
- **Withdraw the preceding 214-million pooled result and target-error figures
  as valid comparisons.** They came from the wrong coordinate convention.
  Group restriction still gave zero cross-group mass, but within-group
  positions were also inverted. None of these transport images were published.
- Stopped our affected native and pooled H3-5 jobs. Restart only with the
  corrected wrapper. This is why image review is part of validation, not just
  a presentation step.

## 22:03 UTC — preview count-correction limit

- A thread sample places the 10,000-tile performance job in minimum-cost-flow
  count correction. Added an optional polishing-iteration limit so an unfinished
  shape preview can be exported without waiting for this stage.
- The first implementation tried to set an upstream final constant and failed
  compilation. Corrected it with a property read in the patched Polisher copy.
  Rebuilt successfully. All eight Python/Java tests pass, including zero polish
  iterations, a one-round limit, and invalid settings.
- This preview option does not imply exact counts or convergence. Keep the
  default polishing stage for reference experiments.
