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

## 22:09–22:23 UTC — graph checks and geographic border order

- The first unpolished world run reached a two-region graph and failed its
  crossing assertion. An axis-aligned two-vertex drawing caused the problem.
  Use a sloped two-vertex drawing and check every graph before optimization.
- The new preflight rejects the old input immediately. Stopped the remaining
  jobs that used that input; their long first stages could not produce a valid
  complete world result.
- A checked five-round world preview now exports all 349 shapes. It preserves
  all 352 represented contacts, with no false contacts or region holes. It has
  57,174 tiles instead of 10,000. Its geographic arrangement is unacceptable.
- Built neighbour rotations from source border traversal. Selecting the first
  occurrence independently on each side of a repeated border is inconsistent.
  Selecting the same shared segment on both sides gives valid planar rotations
  for every connected world graph at 10,000 tiles.
- Preserve these rotations through temporary sea-node augmentation. The new
  five-round preview has 15,118 tiles and still preserves all 352 contacts.
  It remains geographically poor and has 10,544 tiles of absolute count error.
  Neither unpolished image is a valid population map.

## 22:24–22:33 UTC — minimum-cost-flow roundoff

- A small independent flow test stalls with the original Java implementation.
  The world count-correction thread was also repeatedly inside shortest-path
  search. Reduced-cost updates can produce tiny negative residual costs.
- Update each edge once and clamp only roundoff-scale negatives on usable
  edges. Keep inactive reverse-edge costs. Reject larger negative values.
- The first tolerance was too narrow for accumulated roundoff and correctly
  rejected a value near -1e-19. Use a tolerance based on the network scale.
- The patched solver passes 1,000 exhaustive small-graph comparisons, including
  negative decimal costs and edge and vertex capacities. This tests the numeric
  fix; it is not yet evidence that world polishing will complete.
- Tests pass: nine Python/Java tests and eight geometry tests. These include
  consistent shared-border portals and preservation of neighbour rotations.
- Corrected H3-5 transport has 8,545 source aggregates. Grouped transport moves
  zero population across groups and retains 99.757%. The pooled comparison
  moves 83,826,177.77 people across groups and retains 99.753%. The native-cell
  run has reached Sumatra and is still in progress.

## 22:35–22:41 UTC — infeasible counts and initial orientation

- A six-region star proves another upstream assertion error. A one-tile centre
  cannot have five side neighbours. Topology mode must stop with count error,
  not assert that an unchanged polishing pass improved the error. Fixed this
  condition and added an integration test that keeps all five contacts.
- Added an optional rigid orientation step before guide fitting. It compares
  region centres with geographic centres, then rotates or reflects the initial
  square grid. The step preserves cells, counts, and contacts. Later shape and
  position checks are still required.
- The orientation path and infeasible-count test pass. All ten Python/Java
  tests pass. The ongoing reference fits use their earlier frozen class copy;
  they do not receive changes while running.

## 22:44–22:52 UTC — review evidence and provenance

- The frozen reference fit reached the predicted Polisher assertion in a later
  component. Restarted it with the tested fix. Stopped the older large-resolution
  loop before it could launch another job with the same known error.
- The five-round orientation preview preserves all represented contacts and
  has no region holes, but its count error remains above 10,000 tiles. It is
  not a valid population layout.
- Added country axis-order checks for entities with at least 10 million matched
  people, excluding differences below five degrees. The geography-first
  baselines have 48, 41, and 39 reversed comparisons out of 7,500. The oriented
  five-round preview has 1,098. This supports the visual finding that geographic
  arrangement still needs work.
- Corrected the Indonesia coverage caption: missing source coverage is unknown
  by country, not zero. The world join excludes unmatched sources before the
  Indonesia subset is formed. Nearest-polygon diagnostics do not assign them.
- New Java builds record upstream revisions and source hashes in each layout.
  Review archives can refresh derived checks only if their cells and input
  manifest still match. Removed unused planar embeddings from the separate
  geographic-baseline archives; they were not used by that method.
- Refreshed the three world baselines and Indonesia review checks. Production
  targets and solver files remain unchanged.

## 22:54–23:12 UTC — completed fits and border repair

- The all-assertions 10,000-tile topology reference finished. It keeps all 352
  represented contacts, but has 10,411 tiles and 4,593 tiles of absolute region
  count error. Its country axis-order check has 3,217 errors in 7,500 comparisons.
  The oriented fit also keeps the contacts, but count and position errors remain.
- Added a separate greedy border-repair experiment. It keeps exact component
  counts and prevents false contacts, disconnection, and holes. The first
  checked results restore 270 of 352 borders at 10,000 tiles and 312 of 368 at
  55,000. Long thin connectors damage shape. These are not production layouts.
- Added rollback and repeated-move tests. All 12 geometry tests pass. The final
  script records its hash at load time. Restarted the large repair runs after
  adding input checks, so their source hashes identify the code actually used.
- Added an independent CSV transport checker and corruption tests. All four
  corrected coarse transport exports pass. The checker does not renormalize
  missing mass. Native H3-8 grouped transport is still in progress.
- Started tighter-spacing repair comparisons and exact-mode Java fits. The
  latter may break borders; independent checks will decide what they preserve.

## 23:13 UTC — saved comparisons

- Saved border-repair images at all three world resolutions. The 110,000-tile
  result restores 311 of 382 represented borders. More tiles do not guarantee
  more retained borders with this greedy method. All three keep exact counts
  and pass independent connectivity, no-hole, and no-false-contact checks.
- Saved the complete 10,000-tile topology reference and oriented comparison,
  including their large count errors. Added the images and limits to the gallery.
- Published corrected coarse transport results with flow tables, target errors,
  independent checks, and input hashes. The native result remains pending.

## 23:17–23:33 UTC — larger fits and sparse balance

- The complete headless test suite passes: Python/Java layout, geometry, CSV
  transport checks, and all three Julia suites. The original Indonesia audit
  also passes. Logs stay under `output/auto-cartogram/world-jobs/`.
- The 55,000-budget oriented topology fit finished with 44,616 tiles and 14,808
  tiles of absolute component error. It preserves all 368 represented borders
  but is not a valid population map. Saved its image and independent checks.
- All nine spacing/repair combinations finished. Tighter placement improves
  some compactness values but increases missing borders and country order
  errors. Saved a parameter table and one compact comparison image.
- Tested sparse iterative proportional fitting after transport. H3-5 grouped
  weights reach full source retention to floating-point precision, zero
  cross-group mass, and relative target error below 1e-8. H3-3 grouped support
  has a measured capacity obstruction; no corrected export is written.
  H3-5 pooled scaling stops at its iteration bound without an accepted export.
- Inspected a stack sample from exact-mode Java. It is spending time in
  hole-boundary checks during final polishing, not the earlier flow stall.
  Its external timeout remains active. A separate default-settings topology
  fit is testing whether the bounded previews stopped too early.

## 23:34–23:43 UTC — native identity checks and map-unit union

- Added an independent native-source check. It compares each exported source
  ID, population, component, and group with the original Arrow file and group
  table. Synthetic tests reject changed mass, changed groups, and duplicate IDs.
- Found an important modelling distinction: some Natural Earth map units share
  a border within one country. They are not separate islands. Added an optional
  union stage for these units before population budgets are allocated.
- The world union reduces 4,292 polygons to 4,274 through ten merged groups.
  It keeps all 7,954,677,990 matched people. No snapping or cross-country union
  is used. A full contact comparison finds all 384 expected contacts after
  union, with none added or missing. Saved the original-to-dissolved ID table.
- The geometry suite now has 16 passing tests, and the Julia layout suite has
  34 passing checks. Corrected a Julia entry-point parse error and a synthetic
  test dictionary type before the successful runs.
- Started three-resolution topology and geography comparisons with dissolved
  country outlines. Earlier map-unit results remain available as comparisons.

## 23:43–00:48 UTC — completed native transport and new world previews

- Long native and Java runs continued during this interval. At 00:43, inspected
  the completed native Indonesia export. It has 832,166 source rows and
  1,432,890 mapping pairs. Both independent flow checks and original-source
  identity checks pass. Cross-group mass is zero; retained mass is 99.883%.
  The largest target error is 7.350%, in the Java group. Native sparse balance
  correction is now running with a one-hour limit.
- Both 10,000 and 55,000 exact-mode fits failed the same upstream assertion: a
  changed exact-polish pass did not reduce total tile error. Stopped the pending
  110,000 exact-mode test instead of repeating the known failure. Did not remove
  the assertion or publish an incomplete result as a valid map.
- The dissolved-outline topology fits at 10,000 and 55,000 finish and retain
  all represented borders, but still have large area and position errors.
  The 10,000-budget count error falls to 1,931 tiles; this is still too large.
- Saved geography-first and border-repair images at all three resolutions with
  the dissolved inputs. The main gallery now starts with these cleaner inputs.
  Earlier map-unit images and checks remain in `early-layouts.md`.
- Started a longer dissolved 10,000-budget fit. Large-resolution and default
  fits remain bounded by their recorded timeouts. No production files changed.

## 00:50–00:55 UTC — whole-shape relaxation

- Added a translation stage before greedy border repair. It keeps each shape
  and tile count unchanged, forbids false contacts, and reduces neighbour-gap
  cost plus a penalty for movement from the baseline. This is a local search,
  not a topology or geographic-order guarantee.
- The first 10,000-tile trial reduces missing represented borders from 60 to
  32 after repair. Weighted compactness improves from 0.175 to 0.193, but country
  axis-order errors increase from 58 to 105. Long connectors remain visible.
- All 17 geometry tests pass, including repeatability, shape preservation,
  contact checks, and decreasing translation cost. Added parent settings to
  repair provenance before the larger parameter comparison.

## 00:57–01:10 UTC — polishing rollback and assertion-status correction

- The longer dissolved fit exposed a non-improving topology-polish pass.
  Added transactional tile rollback: if a partly executable flow does not
  reduce count error, restore all previous owners and stop that polishing
  stage. A forced-flow Java test checks cells, counts, and contacts after
  rollback. Exact mode still rejects unresolved counts.
- Found a mistake in the performance flag and status marker. Java assertions
  in a nested class use the enclosing top-level class status (JLS 14.10).
  Disabling only the nested `MosaicRegion` request did not disable its costly
  checks. Earlier claims that those checks were off are withdrawn.
- Confirmed the rule in the pinned bytecode and with a reflective runtime test.
  Corrected the adapter, commands, and documentation. Saved correction records
  beside affected archives without changing the raw completion markers.
- The correct performance flag disables model-class assertions, not only region
  assertions. Independent final checks remain mandatory. The first paired
  10,000-budget run has byte-identical cells with and without those assertions.
- All 11 Python/Java layout tests pass after the fix. The full-default original
  10,000-budget fit also finished: 1,013 tiles of absolute count error remain.
  Started full-default dissolved fits with the tested performance flag.

## 01:11–01:17 UTC — native balance result and completed comparisons

- Native sparse scaling did not reach 1e-8 within 50,000 iterations. Its
  residual was 2.40e-5. A separate run with an explicit 1e-4 relative tolerance
  finished after 26,348 iterations and 513 seconds of scaling. This tolerance
  is 0.01%, not a production requirement chosen by the user.
- The corrected native export retains all source mass to floating-point
  precision, has zero cross-group mass, and passes independent source and
  target checks. A streaming comparison verifies every one of the 1,432,890
  original ordered pairs. Added a two-panel error image with one colour scale.
- All nine translation/repair parameter tests finished. The 10,000-tile case
  can retain more borders, but the larger tests trade better compactness for
  worse contact or position scores. Saved the table and one example image.
- Both 110,000-budget topology fits finished. The dissolved fit keeps all
  represented contacts but has 39,310 tiles of absolute count error. Saved it
  as evidence of failure, not as a replacement map.
- Updated the main research report with implementation findings and the native
  transport result. Three transport-check/figure tests pass, including file
  tampering and changed pair order.

## 01:18–01:29 UTC — planned transfer destinations

- Found a second polishing fault. The flow names a destination region, but
  execution read the current owner of the destination cell. An earlier move
  could change that owner and send tiles to the wrong region.
- Added a reverse-order three-region transfer test. It fails on the previous
  frozen build and passes with destination owners saved before execution.
  All 11 Python/Java layout tests pass. Kept transactional rollback as a
  separate guard against partly executable flows.
- Started new full-default world fits from a frozen build. The previous
  full-default dissolved fits have 637 and 7,176 tiles of absolute count
  error at budgets of 10,000 and 55,000. The 110,000 case is still running.

## 01:29–01:34 UTC — remove artificial sea constraints

- Tested an initializer with no added sea vertices. NetworkX can draw the
  original dual, but all three world inputs fail upstream geometric preflight.
  Kept the option and tests as a recorded experiment, not the default.
- Found a necessary count conflict in the augmented dual. One square tile can
  touch at most four regions. The added sea vertices require five contacts for
  Alaska at 10,000 tiles and Dhekelia at 110,000. The original land graph has
  no degree-bound conflict at these three budgets.
- Added a separate option that removes sea regions after grid initialization,
  before population fitting. It copies all land cells and contacts into a new
  dual and recalculates the placement weight. All 12 Python/Java layout tests
  and 19 geometry tests pass, including an end-to-end four-region example.
- The first 10,000-budget result improves absolute count error from 631 to 313
  tiles and country axis-order errors from 672 to 497. All represented borders
  remain, with no false contacts, disconnected shapes, or region holes. This
  is still not an acceptable population map. Larger and exact-mode trials run
  from the same frozen build.

## 01:36 UTC — initialization sensitivity

- Started eight 10,000-budget fits with fixed rotations and reflections of
  the planar drawing. These preserve the contact graph and all pair distances.
  The later grid orientation and all fitting settings stay fixed. Each run
  has a 30-minute limit; the matrix has a 03:40 UTC deadline.
- Added tests for all eight transforms and invalid values. All 20 geometry
  tests pass. The first land-only exact-mode run still fails its final count
  check. It exports no completed layout.

## 01:38 UTC — exact-flow supply limit

- Found that exact polishing can supply one unit from each surplus region,
  not one unit in total as its comment requires. Added a two-surplus-region
  regression. It fails on the previous frozen build for this specific reason.
- Changed exact-mode setup to select one nonzero region supply and balance it
  against the sea. The topology-mode setup is unchanged. All 12 Python/Java
  layout tests pass. Started new exact-mode fits with one-hour limits and the
  overall 04:20 UTC compute deadline. Counts are not accepted until reviewed.
