# Compact landmass work log

## Work window

Start: 2026-10-14 14:40 UTC. New deadline: 2026-10-15 06:00 UTC.
This replaces the previous 19:50 UTC deadline. Record completed work, not elapsed
background time as manual work. Keep production code and targets unchanged.

## Acceptance criteria

- Use OWID as the visual compactness benchmark.
- Start the first joint-deformation trial from the Tutte partial fit.
- Reduce empty spaces between countries, including gaps open to the ocean.
- Do not recreate thin paths to force distant territories to touch.
- Keep exact component budgets, connected components, and no overlaps.
- Report lost and false borders. Do not hide them behind aggregate scores.
- Inspect world and regional images before selecting a candidate.

## 14:40–14:52 UTC — measure the failure and start joint deformation

- Added empty-space measurements for the union of all occupied cells. These
  include enclosed empty regions, land-sea edges, and disk-closing masks at
  radii of 1, 2, 4, and 8 tiles. The last measure includes open gaps.
- These are diagnostic proxies, not a reliable classification of artificial
  water. They also count some real lakes, bays, and straits. The images show
  where each proxy applies. The four scales prevent reliance on one radius.
- The OWID file has 54,978 rows and 54,967 distinct coordinates. Eleven
  coordinates have both South Africa and Lesotho labels. The empty-space
  benchmark uses the occupied union and reports those overlaps. No source file
  was changed. OWID and the new layouts also have different population scopes.
- Visually inspected OWID's colour image and the three gap masks. The separated
  layout has large marked spaces inside Africa, Europe, and Asia. OWID has a
  much more continuous continental interior. The masks also mark real water,
  especially around islands; a lower score alone cannot approve a layout.
- Added a separate land-sea boundary cost to the joint cell-exchange solver.
  Unlike the existing country perimeter cost, it charges exposed edges but not
  shared country edges. This tests whether joint deformation can close internal
  gaps without adding border paths. The cost also affects real coasts; inspect
  coast loss before accepting a result.
- Started Tutte-derived trials with sea-edge costs of 0, 2, and 8. They use the
  same shape guide and false-contact cost. Count fitting stalled before exact
  budgets, so their results must remain marked as partial.
- Found that count fitting considered only the cheapest transfer on each graph
  edge. If that transfer broke connectivity, it could miss valid alternatives.
  Added bounded alternative searches and a strict proposal filter before
  candidate truncation. Added a regression test with a removable endpoint and
  a forbidden middle-cell removal. Started further count-fit trials.
- All 34 focused tests pass. Solver and metric changes are committed before
  their corresponding trials start. No new solver image is approved yet.

## Baseline measurements

| Layout | Occupied cells | Enclosed empty cells | Land-sea edges | Closing additions, radius 4 |
| --- | ---: | ---: | ---: | ---: |
| OWID | 54,967 | 172 | 7,364 | 4,549 |
| Tutte partial | 53,017 | 1,020 | 9,154 | 5,045 |
| Separated shapes | 55,000 | 2,371 | 16,702 | 11,283 |

The Tutte fit still has an absolute budget error of 2,011 cells. These values
are not a controlled comparison with identical population and country scopes.
The separated layout has exact budgets but is not an acceptable replacement.

## 14:56–15:26 UTC — first visual rejection and stronger checks

- All eight test commands passed at checkpoint `dc09224`. Full source hashes
  are in `results/compact-landmass/validation-1456/validation.json`.
  That run had 34 focused shape tests. The current focused suite has 37 passing
  tests after the later changes below.
- Recomputed all three saved gap benchmarks from their compressed cells and
  checked their hashes. All measurements match. A local HTTP server returned
  status 200 for the page and its 13 linked resources.
- Reviewed both initial joint world images. Also inspected the strong sea-edge
  trial's Europe and Indonesia images. Reject both trials. Japan and Great
  Britain become rectangular, Indonesian coast detail is lost, and long paths
  remain in Europe. The stronger cost has only 3,809 radius-4 closing additions,
  below OWID's 4,549, but its map is clearly worse. Do not optimize this proxy
  alone. Both initial trials also retain budget errors.
- Saved these failures with cells, metrics, settings, source hashes, and images.
  Repeated their saved numeric checks without the generator input directory.
- The strict count-fit proposal filter reached exact budgets in 139 rounds.
  The corresponding deformation continues. Stopped the two superseded
  alternative-only count-fit trials; both still had large budget errors.
- Found another guide issue: the area guide used the incomplete starting count
  even when count fitting requested a much larger region. It now uses the
  requested budget in count-fit runs. Added a test for this distinction.
- Isolated components can now remain fixed during unbounded shape optimization.
  This protects island silhouettes after count fitting. Added checks that a
  fixed component cannot gain or lose cells, including through whole-region
  regrowth. Downstream island records now include parent deformation settings.
- Added an optional fixed land envelope for the extra sea-edge cost. It includes
  initial land and a radius-4 closing mask. It does not tax every outer coast.
  Tests compare both individual and whole-region energy changes with a complete
  recomputation. This mask can still contain real water, so visual checks remain
  necessary.
- The Tutte centres themselves preserve poor country positions. A further trial
  keeps Tutte starting cells but takes guide centres from the automatic
  geographic layout. A positive uniform scale and translation align the guide
  centres; no rotation, country template copy, or OWID position is used.
- Added a country-level OWID border comparison. After explicit source code
  mappings, all OWID codes map to 203 source country IDs. OWID retains 248 of
  311 source country pairs and has 48 contacts absent from this source. The
  separated layout retains 114 pairs with zero unsupported contacts. These
  measurements do not compare component topology or prove correct positions.
- The new comparison test exposed a single-row grid-step bug. Fixed the missing
  axis handling. Tests also reject ambiguous source code mappings.

## 15:26–15:46 UTC — direction benchmark, paper review, and solver cost

- A full validation attempt exceeded its 300-second harness limit after seven
  successful commands. The production CPU command had no completed result.
  Repeated all eight commands with a longer limit and saved each result as it
  completed. All eight passed; the focused suite then had 37 tests. Logs and
  source hashes are in `results/compact-landmass/validation-1532/`.
- Added matched-scope direction checks for 92 countries with at least 10 million
  source people. They use the largest connected output piece and a five-degree
  source separation. Out of 7,496 axis comparisons, OWID has 210 reversals,
  Tutte has 1,368, and separated shapes have 157. The first strong sea-edge
  trial still has 1,356. These checks omit small-country position errors and
  are not a complete visual score. They show why fixed Tutte guide centres
  cannot be the final objective.
- Re-read sections 4.2 and 6 of the supplied 2015 paper. The paper moves guiding
  shapes between deformation stages. Its discussion explicitly identifies
  rigid guiding shapes and large final size corrections as causes of thin
  extensions. It proposes non-uniform scaling as further work. This supports
  testing controlled guide deformation rather than more rigid placement.
- Found a repeated computation cost: each round regrew every large region,
  even after all relevant cells stopped changing. Added an optional cache of
  failed regrowth attempts. It records every occupancy lookup, including
  rejected growth cells and nearby contact checks. A changed dependency forces
  a new calculation. Costs and masks remain fixed during each run.
- The focused suite now has 38 passing tests. Cached and uncached runs match
  across random bounded and unbounded cases and the file pipeline. Started a
  full-size cached repeat to check final cell equality. Also started an
  80-round geographic-guide preview for earlier visual inspection.
- The corrected full-size deformation trials continue. No exact-budget joint
  layout has completed visual review yet. Production code remains unchanged.

## 15:54–16:24 UTC — reject exact fits and test a shared footprint

- Inspected the exact Tutte fit with an interior sea-edge cost. Island outlines
  survive, but Europe still has thin paths and poor positions. Reject it.
- Inspected the geographic-guide world image and Europe detail. Some positions
  improve, but Germany surrounds Belgium, Portugal is inside the Balkan group,
  and cuts remain through China. Exact counts do not correct these faults.
- Inspected the geographic-start control. It has exact counts, but large gaps
  remain and several mainland countries become rectangular. Reject it too.
  It has 311 enclosed empty cells but 7,993 radius-4 closing additions. This
  shows why enclosed holes alone are not a sufficient measure.
- Saved these three results, with compressed cells, input records, checksums,
  world images, and regional images. No result is approved.
- Moved isolated islands before a further Tutte trial. This explicit partial
  mode preserves the 2,011-cell budget error and all 348 borders. It puts Sri
  Lanka beside India rather than inside a mainland cut. The default island
  stage still rejects incomplete budgets.
- Audited source holes. Only three holes contain a complete represented
  component: San Marino, Baikonur, and Lesotho. The current no-hole rule also
  rejects these occupied holes. A safe enclave rule needs checks when either
  the host or the enclosed component changes. It is not implemented yet.
- Added local topology checks with complete checks for non-simple changes.
  Exhaustive local tests and random comparisons agree with full validation.
  The focused suite now has 40 passing tests, including the footprint tests.
  These latest changes have not yet passed another complete eight-command run.
- The full-size failed-regrowth cache repeat completed. Its cell file is
  byte-identical to the uncached interior trial (SHA-256 starts `f4709c6f`).
  The separate fast-topology repeat is still running.
- Stopped the older global sea-edge trial before completion. Better controlled
  exact-count trials had completed; the stopped trial has no final layout.
- A perimeter cost can close a gap entrance without filling the gap. Added an
  optional area-matched target footprint: select as many target cells as there
  are movable land cells, then charge for land outside that footprint. A target
  that contains all starting land would give a constant area cost instead.
- The footprint uses a smoothed land mask. It excludes fixed islands and their
  immediate neighbours. The inspected scale-8 preview has 49,894 target cells
  in five pieces and 8,005 initially empty target cells. It is not a verified
  coastline: some small countries and Chile lie outside it. The cost is finite,
  so shape guides can oppose it. Two weight trials started at 16:18 UTC.

## 16:24–16:28 UTC — a global partition diagnostic

- Added a separate capacity partition of the same target footprint. It assigns
  every movable target cell, so internal gaps cannot remain inside the mask.
  Isolated islands stay fixed. This tests the limit imposed by local exchanges.
- The solver uses a smoothed transport dual, with four decreasing smoothing
  scales. A final greedy correction makes counts exact. It does not enforce
  connectivity, holes, borders, or optimality after correction. These limits
  are in the output metadata and image caption. This is a diagnostic, not a
  replacement generator.
- Read the [transport dual notes](https://www.gpeyre.com/ot4ml/slides/3-dual-semidiscrete/index.html)
  and [SciPy optimizer documentation](https://docs.scipy.org/doc/scipy/reference/optimize.minimize-lbfgsb.html)
  directly. The notes give the cell-mass gradient for a weighted partition.
  Here the source is a finite set of tiles, not a continuous measure. Smoothing
  avoids claiming that the unsmoothed discrete objective is differentiable.
- Five new tests pass: gradient, residual correction, exact counts with ties,
  one label, and invalid inputs. The 40-test shape suite also passes, including
  a new file-pipeline check. Full-world results have not yet been inspected.

## 16:28–16:36 UTC — checks and footprint trial review

- All nine validation commands passed at commit `34cd57f`: the previous eight
  commands plus the new capacity-partition tests. Logs and source hashes are
  in `results/compact-landmass/validation-1629/`. Production files are unchanged.
- Inspected both completed footprint-cost world images. Reject weights 4 and
  16: large spaces remain in Africa and Asia. Increasing the cost does not
  solve the local movement limit. The stronger result also makes Russia and
  several African countries more rectangular.
- Inspected the islands-first geographic-guide world. It removes the large
  cut through India, but Europe, central Africa, and China still have thin
  shapes or cuts. It is not an acceptable replacement.
- Started two global partition controls at 16:28 UTC. One uses source-outline
  guide costs; the other uses only the existing area-normalized centre cost.
  Both remain diagnostic. The first smoothing stages hit their iteration
  limits. Do not report convergence merely because final counts can be repaired.

## 16:36–16:40 UTC — saved results and partition controls

- Recomputed all numeric layout and gap checks for the three saved exact fits
  from their archived cells and input records. They match. All bundle hashes
  match too. The comparison page and its 26 linked local resources return HTTP
  status 200. Reports are beside the latest validation record.
- Added independent guide positions and a uniform squared-distance control to
  the partition diagnostic. Unlike the earlier area-normalized centre cost,
  the uniform cost defines a power diagram before discrete count correction.
  A non-convex target mask can still split its regions.
- Started a compact Tutte-footprint control with geographic target centres and
  uniform distance costs. It can change country positions globally rather than
  preserve the initial nested shapes. The 40 shape tests and five partition
  tests pass after this addition. These additions are later than the full
  validation checkpoint and have only these focused checks so far.

## 16:40–16:50 UTC — global results and landmass scope

- Waited five minutes for the running computations. This was compute time,
  not continuous manual work. All three partition controls completed.
- Inspected all three world images. The global partition removes many small
  spaces and tangled outlines. The compact Tutte-footprint control gives a
  much clearer Europe than the local exchanges. It still has poor large-scale
  geography, a gap north of India, and cuts near misplaced small components.
- None passes topology checks. The outline-cost result has 52 disconnected
  regions and 1,837 cells outside their largest connected pieces. The compact
  power control has 45 disconnected regions and 407 such cells. These are not
  valid replacement layouts. Add visible topology warnings to their images.
- Found a scope error in the global diagnostic: one common footprint quota
  permits American country area to move into Europe. The outline trial puts
  353 US cells outside its main piece. Added a separate optional partition for
  each connected group of source land-border components. Each group gets its
  own exact area; other groups and fixed islands reserve their starting cells.
  Earlier target cells are also reserved. This does not guarantee connected
  countries or preserve every border within a group.
- The source graph has ten such land-border groups. They include Afro-Eurasia,
  the Americas, and individual divided islands. This uses component borders,
  not country membership, so overseas possessions do not create links.
- All six partition tests and 40 shape tests pass after this change. The full
  validation checkpoint precedes this change.
- Both full-size fast-topology repeats completed. Their cell files match the
  original interior fit and the 80-round geographic-guide fit byte for byte.

## 16:50–16:58 UTC — footprint quality remains a separate problem

- Saved two global diagnostics with compressed cells and target masks, settings,
  checksums, and world and regional images. The gallery now shows their
  connectivity failures rather than presenting them as candidates.
- Added a shared viewport calculation for world and regional images. New SVG
  files record the map header height. Regional crops also support old files
  that do not have this field. Inspected the updated Europe detail: the crop
  and labels align, and the topology warning is visible.
- The landmass power controls completed. Inspected the geographic-start image
  at smoothing scale 16. It fills the large central African hole, but makes
  rounded land blocks and separates China from the rest of Asia. The footprint
  itself needs correction; exact partitioning cannot fix its outer shape.
- Re-inspected the earlier continuous-flow world image. Its country outlines
  are too thin, but its large-scale arrangement puts India west of China and
  north of southern Africa. Test its footprint and sites without retaining its
  thin internal country boundaries.
- Added a flow-footprint adapter. It rasterizes validated component polygons,
  translates intact isolated-island templates near the flow sites, and keeps
  the original budgets. The raster mask is only a density sample: a landmass
  target must use the requested area, not the sampled pixel count. This also
  avoids adopting the upstream solver's raised minimum country areas.
- The adapter reports components too small to rasterize, validates all labels,
  and records geometry and code hashes. Seven partition tests and 40 shape
  tests pass, including a flow-mask pipeline with exact original budgets.
  No new flow-footprint result has completed visual review yet.

## 16:58–17:06 UTC — flow review and a bounded repair test

- Started two power-partition flow trials at scales 4 and 8, plus an outline-cost
  control at scale 8. Inspected the completed scale-4 power image. The large
  country arrangement improves, but North America and Africa remain too narrow.
  There are 36 disconnected regions. The result is not approved.
- Added a fragment repair that only swaps existing tile labels. Counts, fixed
  islands, and the occupied footprint cannot change. Each accepted swap must
  reduce cells outside the largest connected pieces and must not increase
  either region's component count. No connector cells are added.
- The repair can fail when a fragmented country has no suitable shared boundary
  for a compensating swap. It reports remaining fragments. Occupied country
  holes are allowed here; they are not empty cells in the land union. This is
  a different, explicit topology policy from the earlier no-country-hole solver.
- Nine partition tests and 40 shape tests pass, including random swap sequences
  and a file-pipeline check. A full-world repair has not been reviewed yet.
- Re-inspected OWID. Its compact internal land, geographic arrangement, and
  recognizable broad coast shapes remain the target. Better local gap scores
  do not compensate for narrow continents or displaced large countries.

## 17:06–17:51 UTC — connected partitions and visual checks

- Added an explicit fragment-relocation option. It removes secondary pieces and
  grows the main piece by the same number of cells. It does not draw paths to
  the removed pieces. Counts remain exact; coasts can change. A blocked region
  can still fail. The output records each removed and added cell.
- Added an island-only mode that can preserve reported mainland defects. It
  must not change fixed mainland cells or represented contacts, and must not
  add false contacts. This is not permission to hide existing defects.
- The flow-footprint trial with horizontal stretch 1.5 now has 55,000 cells,
  no disconnected components, 197 enclosed empty cells, and 7,546 land-sea
  edges. OWID has 172 enclosed empty cells and 7,364 edges. Different population
  and country scopes prevent a controlled comparison. The new map still loses
  125 component contacts and adds 133 unsupported contacts.
- Inspected its world image. The large internal gaps are much smaller. Africa
  and North America remain narrow; China is flat; Russia is too far east.
  Exact counts and better gap scores do not make this a replacement for OWID.
- Measured population sites from 32,668,501 matched native H3 centres. Group
  masses match the prepared inputs. Russia's main component has a population
  site near 52 degrees east, rather than the polygon centroid near 99 degrees
  east. The centroid here is measured in longitude and latitude, not in the
  projected guide plane. Source year remains unspecified.
- Inspected rigid placement at these population sites. Russia moves west, but
  greedy collision removal changes country order. Reject rigid placement.
  Added validated site input to the global partition instead. It uses one
  positive uniform scale and translation, not rotation or reflected axes.
- All nine full test commands passed at the 17:26 checkpoint, before the later
  flow-guide and pipeline changes. The current focused suites pass 14 partition
  tests and 40 shape tests. An initial site-input test found a local variable
  that hid the input path; renamed it and repeated both suites successfully.
- Added a recorded, headless multi-resolution pipeline. Restarted the runs from
  an immutable copy of commit `68612f4` so later edits cannot change imported
  code halfway through a run. The stopped runs have explicit stop records.
- Inspected the 10,000-tile world image. It has exact counts but one disconnected
  region. Continents remain too narrow and the Koreas are displaced. The
  110,000-tile run is still computing. The 500,000-tile flow run returned exit
  status 1: its maximum area error was above its convergence threshold. The
  pipeline stopped and recorded the failure. Do not treat that as success.
- Inspected both flow-guide weight controls, 0.5 and 2. The stronger guide
  retains more source borders but leaves one split region. Weight 0.5 has no
  split regions, 112 missing contacts, and 115 false contacts. Also inspected
  its Europe, Africa, Indonesia, and South Asia details. Europe no longer has
  nested countries, and Indonesia retains island detail. South Korea is still
  separated from North Korea; Southeast Asia has rectangular blocks; North
  Africa is too narrow. Neither control is approved.
- Two global partitions with native population sites are running. These test
  country positions without using the greedy placement's final country centres.
  Production code and targets remain unchanged.

## 17:51–18:02 UTC — saved comparisons and further controls

- Saved the connected 55,000-tile controls and the 10,000-tile world diagnostic.
  Recomputed all layout and gap measurements from their compressed saved cells.
  All values match. Checked every saved bundle hash.
- The native-site trials initially stopped because an unused outline guide lay
  outside the cost grid. Power partitions need only site distances. Removed
  their unused dense outline grids, added a regression test, and repeated the
  power trial. The outline-cost trial remains a recorded failure.
- Inspected the native-site power world image. Russia is farther west, but
  South America is split across distant land pieces, Japan is south of China,
  and large holes remain. Three regions are disconnected. Reject this result.
- The fixed-island reservation can itself leave holes when a mainland expands
  past an island. Added an explicit control that does not reserve isolated
  island cells in the mainland target. It moves intact islands outside the
  assigned land with a side-neighbour gap. Counts and island shapes are checked.
  This can change island order and is not an automatic approval.
- Added a second control: native population sites on a continuous-flow
  footprint. This separates the source of country positions from the source of
  the outer land shape. Trials with zero and 0.5 flow-guide weight are running.
- Inspected the completed 110,000-tile world image and its Europe, Africa, and
  Indonesia details. Island detail improves, but the thin continents remain.
  Counts are exact; one region is still split. Saved this result with visible
  warnings. Repeated all four archive checks and 61 local HTTP resource checks.
- The 500,000-tile flow retry at grid size 512 also failed its one-percent area
  threshold. Its final maximum adjusted-area error was about 8.43 percent.
  A separate run with a ten-percent tolerance also failed, at about 17.15
  percent. These are separate solver trajectories, not a monotonic convergence
  test. Added explicit grid and tolerance settings to the recorded pipeline.
- Started a clearly labelled guide-only diagnostic from the first 512-grid
  approximate geometry. It must pass geometry and overlap checks. Final tile
  budgets still come from the original input, not the adjusted flow areas.
  The external area solve remains a failure regardless of this later result.
- The 14 partition tests pass after these changes. Saved population sites and
  documented their limits. No production code or target file has changed.

## 18:02–18:12 UTC — separate position, footprint, and shape tests

- All nine full test commands passed at checkpoint `b0ff8a2`. This check took
  about three minutes of foreground compute time. It preceded the docking
  change below. The current focused suites pass 15 partition and 40 shape tests.
- Inspected the three new world controls. Moving isolated islands removes some
  small holes but does not repair the poor geographic-start footprint. The
  population-site flow control with guide weight 0.5 has exact counts, no split
  regions, and no region holes. It loses 83 component contacts and adds 95.
  A separate matched-country check retains 241 of 311 required border pairs,
  with 71 unsupported pairs. OWID retains 248, with 48 unsupported pairs.
  The matched large-country axis check has 218 reversals, compared with OWID's
  210. Country shapes are still poor. North Korea
  occupies a separate land piece. These results are not approved.
- The shared target itself has four parts in the Afro-Eurasian source-border
  group and two in the Americas. Added an explicit docking control: translate
  whole target pieces until they touch, without adding path cells. It preserves
  their total area and each piece's shape. It does not join separate source
  land-border groups or overseas territories by country ID. The method can
  still change coasts and country positions, and a contact can be narrow.
- Started two docking controls from the flow footprint and population sites.
  Their country sites do not move with the target pieces. This is a limitation
  to check in the resulting country assignment, not a hidden constraint.
- Started two local joint-deformation controls from the connected population-site
  flow layout, rather than from the poor Tutte arrangement. They use source
  outline guide weights 4 and 16, an interior sea-edge cost, and fixed isolated
  island shapes. Both have a 100-round limit and use a saved code snapshot.
  They test whether a better starting arrangement permits useful shape changes.
- The 500,000-tile guide-only run passed its separate geometry and overlap
  checks. Tile partitioning is still running. Saved all three failed external
  flow logs and their status separately; no failed solve is marked successful.

## 18:12–18:29 UTC — reject local corrections and test a different guide

- Inspected the two completed docking world images. The zero-guide control puts
  the Koreas together and connects the Americas, but leaves one stray Zimbabwe
  tile inside East Africa. Its main Zimbabwe piece is enclosed by other labels,
  so direct growth into empty space cannot replace that tile.
- Added an explicit coastal-compensation fallback. A neighbour gives one cell
  to the blocked region, then grows one cell into empty space. The old fragment
  cell becomes empty. The exchange is transactional, keeps all country counts,
  preserves connectivity, and leaves fixed islands unchanged. It has strict
  search limits and can still fail. It does not draw a path to the old fragment.
- This removes Zimbabwe's stray tile in the docking control. Inspected the new
  world image and its Africa and South Asia details. There are no split regions,
  but three region holes remain. The Americas and Koreas are better arranged;
  an odd narrow feature remains on China's north coast. Reject production use.
- Inspected both local source-outline corrections from the better flow start.
  They reopen gaps and damage borders. Also inspected global coast penalties
  16 and 64 with isolated islands fixed. The stronger cost has just 34 enclosed
  empty cells, but turns the USA and China into blocks. Reject all four local
  controls. The isolated-island fix alone cannot solve mainland shape quality.
- Saved the population-site control, the repaired docking control, and two
  representative local failures with world and regional images and cell data.
  The gallery states their defects and does not select a production replacement.
- Re-read section 6 of the 2015 paper. It identifies rigid guiding shapes and
  large final area corrections as causes of thin extensions. It proposes
  non-uniform scaling as future work. A global horizontal stretch is not an
  implementation of that adaptive per-region proposal.
- Added a guide-area relaxation control. It preserves each source-border and
  continent group's total guide area, but reduces within-group density extremes.
  The final tile budgets remain the original population budgets. These relaxed
  areas must never be presented as population targets.
- The first regional preparation stopped on dissolved map-unit codes such as
  BIH. Added a source-based fallback only when all map units of the country have
  one continent label. Seven current fallbacks are unambiguous. Tests reject
  mixed-continent fallback records. The failed runs remain separate.
- Started fresh regional-guide trials at blend weights 0.25 and 0.5, using an
  immutable copy of commit `9bf5f8f`. Their output has not been visually reviewed.
  The 500,000-tile guide-only partition is still running. Its first two smoothed
  dual stages reached their iteration limits; final counts are not yet available.
- The current partition suite has 17 passing tests. Production code and target
  data remain unchanged. The work window has not ended.

## 18:29–18:53 UTC — regional controls and multi-resolution repairs

- All nine test commands passed at checkpoint `9dc336c`. Saved their logs in
  `validation-1831`. Later changes pass the 19-test partition suite; this is
  not yet a new full-suite result.
- Inspected both relaxed-density guide worlds. Spain moves against North
  Africa, China remains flat, and the Americas remain narrow. Both have exact
  counts and no split regions, but neither is a production candidate.
- Tested population sites on the earlier stress-shaped footprint, with
  smoothing scales 8 and 16. Inspected both world images. Large gaps remain,
  and some African countries move into the footprint south of India. Reject
  both results. An outline-cost control is still running with many fragments.
- Added a two-level regional quota control. It assigns regional budgets first,
  then country budgets inside each region. Original population counts do not
  change. Inspected its flow and stress worlds. It prevents the most extreme
  Africa-to-Asia moves, but the stress world still has large holes, thin shapes,
  and poor island positions. The flow world still has Spain against Africa and
  separated Koreas. Neither control is selected.
- Corrected floating-island placement to use fitted guide sites when available.
  Also stopped unused island outlines from enlarging or invalidating the
  mainland cost grid. Added regression tests.
- Extended coastal compensation to bounded chains through adjacent regions.
  Tests cover a nested interior region and rollback when the depth limit stops
  an exchange. No path is drawn to an old fragment.
- The 10,000-tile chain repair removes the last split region. Inspected its world
  image: exact counts and no region holes, but 145 missing and 153 false
  represented contacts remain. The Americas are separate and North Africa is
  narrow. Connectivity alone does not make this a good map.
- The 110,000-tile single-donor repair also has no split regions. Inspected its
  world image; the existing shape defects remain. Five region holes include
  occupied holes and must not be described as five empty land holes.
- The 500,000-tile guide-only partition finished in 2,248 seconds. Its repair
  stage is still running. This uses geometry from a failed external flow solve,
  not a converged external result. Production files remain unchanged.

## 18:53–19:08 UTC — stretch controls and repair cost

- Saved the connected 10,000- and 110,000-tile controls. Recomputed all layout
  and gap metrics from their compressed cells. All ten saved controls pass the
  archive checks, and all 80 gallery resources return successfully over HTTP.
- All nine test commands passed at checkpoint `3c3ef8d`, before the repair
  optimization below. Logs are in `validation-1857`.
- Inspected world images with horizontal stretch 1 and 1.2. China is less flat,
  but Africa and the Americas become narrower. Japan moves too far south and
  the Koreas remain on an odd northern extension. Both have exact counts and
  no split regions. Neither is selected. Global stretch cannot correct these
  different regional shape errors.
- Profiled a candidate repair optimization on the 500,000-tile partition. An
  initial version did unnecessary topology work for interior fragment cells;
  that version was slow and was not committed. Moved the work after candidate
  selection and cached repeated donor topology and frontier choices.
- Compared the optimized method with the saved earlier implementation on 200
  seeded random layouts, for eight steps each. Swap records and resulting cells
  match. On the first three 500,000-tile swaps, records and cells also match:
  the new version takes 0.54–0.57 seconds per step versus 5.82–6.12 seconds for
  the earlier version. This is a small timing sample, not a whole-run speedup.
- Added random-grid regression checks for counts, fixed islands, occupied cells,
  exact component partitions, and strict fragment reduction. The 20 partition
  tests pass. The 40 shape tests passed before the final cache adjustment.
  Existing background jobs still use their original saved code.

## 19:08–19:21 UTC — first 500,000-tile image and upstream island control

- Started two fresh repairs of the saved 500,000-tile partition, with limits of
  100 and 2,000 strict swaps. Both use immutable code from `a0ef7a6` and the
  optional coastal fallback. The original pipeline continues separately.
- The 100-swap control finished in 452 seconds, including island placement and
  reviews. It has exact counts and no split regions. Inspected its world,
  Indonesia, Europe, and gap images. Reject it: the USA is rectangular, Canada
  is displaced, and the Americas remain separate. More resolution preserves
  isolated island detail but does not correct a poor mainland footprint.
- Saved this control with its failed-upstream-flow status. It has ten region
  holes, 119 missing contacts, and 151 false contacts. Its 27,823 enclosed empty
  cells include the Mediterranean. Do not call all of them artificial holes.
- The gap SVG exceeded the renderer's default XML attribute-size limit. Split
  cell commands into bounded paths instead of disabling the parser limit.
  Added a regression test. The first render had visible path-edge seams;
  crisp square-cell rendering removes them. Inspected the corrected image.
  This changes rendering only, not gap measurements.
- Inspected the pinned external solver's area replacement code in
  `src/cartogram_info/cartogram_info.cpp`, lines 213–284. It raises some small
  targets, subject to geometric-area and density bounds. Thus isolated islands
  can influence deformation before the later island-shape preservation stage.
  This is a possible cause to test, not a demonstrated explanation.
- Added mainland-only flow preparation. It excludes isolated components, not
  overseas parts by country ID. Partial flow geometry requires population sites
  for the absent islands; missing mainland geometry is rejected. Final budgets
  and intact island templates remain unchanged.
- The 55,000-tile control excludes 292 isolated components from the flow and
  keeps 189 land-border components, with 49,894 guide tiles. The external solve
  exits successfully in 11 seconds; geometry is valid with no overlap pairs.
  All 55,000 final tiles are still requested.
- Inspected its first world image at stretch 1.2. North Africa is wider and Japan
  is farther north than in the full-flow control. However, Pakistan is still
  stretched, Korea extends from the wrong part of China, and Southeast Asia
  remains poor. No production approval. The stretch-1.5 control is running.
- All nine test commands passed at checkpoint `b69ad5d`. After the SVG fix,
  the shape suite has 41 passing tests. Production files remain unchanged.

## 19:21–19:26 UTC — compare mainland-only flow and freeze gap geometry

- Inspected the completed stretch-1.5 mainland-only world. It has exact counts,
  no split regions, and no region holes, but China becomes too flat again.
- Compared both mainland-only controls with OWID on the same matched country
  scope. Stretch 1.2 retains 249 of 311 borders, but has 82 unsupported contacts
  and 227 direction reversals. OWID has 248, 48, and 210 respectively. The
  higher retained-border count does not establish better quality. Stretch 1.5
  is weaker: 240 retained, 85 unsupported, and 237 direction reversals.
- Saved both controls, their external-flow logs, and the country comparison.
  Started guide weights 2 and 8 from the stretch-1.2 mainland-only footprint.
  These tests change assignment costs, not requested population budgets.
- Added a fixed-footprint mode to the basic boundary exchange method. It permits
  only country-to-country swaps. It checks unchanged occupied cells, exact
  counts, and the existing connected, hole-free region conditions. It excludes
  count fitting, atomic moves, and regrowth. This tests border changes without
  reopening the gaps that earlier local deformation controls created.
- Started fixed-footprint false-border costs 4 and 16 from the hole-free
  mainland-only stretch-1.5 layout. Isolated islands are fixed. The 41 shape
  tests pass, including occupied-mask and invalid-option checks.
- The longer cached 500,000-tile repair completed after 204 strict swaps and 21
  component relocations. Its repair stage took 734 seconds; the full recorded
  control took 852 seconds. Inspected the world: the same major defects remain.
  It has no split regions, ten region holes, 118 missing contacts, and 152 false
  contacts. It does not replace the shorter saved diagnostic.

## 19:26–19:42 UTC — inspect border controls and test a mesh objective

- Inspected both stronger mainland guide worlds. Guide weight 2 leaves two split
  regions. Weight 8 has no split regions, two region holes, and better border
  and direction checks, but the main coast and Korea defects remain.
- On the matched country scope, guide weight 8 retains 256 borders, adds 69
  unsupported contacts, and has 198 direction reversals. The fixed-footprint
  cost-16 control retains 251, adds 54, and has 236 reversals. OWID has 248, 48,
  and 210. Inspected both fixed-footprint worlds: they keep gaps fixed and reduce
  border errors, but make some internal borders more angular. No approval.
- Read the September 2026 optimal-transport preprint by Bogdan, including its
  numerical fold and comparison limits. Inspected its world figures. They still
  have very thin features; no native-density transport implementation was added.
- Read Sargent's 2024 planar mesh method, cost functions, and repository README.
  Inspected its plane-cartogram figure. The explicit shape-distortion objective
  looks more relevant than another gap penalty. GitHub metadata did not identify
  a licence for either research repository. No upstream solver code, pickle
  files, or bundled population data were adopted.
- Added an independent planar mesh objective based on the published equations,
  with analytic gradients, fixed frame, area checks, and validity checks. This
  is not the paper's spherical or hybrid solver. Four new tests pass, including
  finite differences, rotations, fixed frame, synthetic area improvement, and
  invalid line-search probes.
- Initial infinite-cost trial steps caused the optimizer to stop without useful
  movement. A finite reciprocal-barrier extension gives recovery gradients;
  accepted stages must still have strictly positive triangle determinants.
- Initial polygon unions exposed numerical seams and, without a precision grid,
  an overlay result that lost a triangle-sized area. Added explicit comparison
  with the sum of mapped piece areas, a small precision grid, bounded seam
  cleanup, and unchanged-hole checks. Synthetic tests now pass.
- Ran the first world guides at grid widths 64 and 128. Both pass geometry
  checks but retain about 97% weighted area error. Inspected the 128-grid world;
  it is still close to an ordinary geographic map. The solver's relative-change
  stopping condition does not establish area accuracy. Reject both guides.
- Replaced tiny country-box samples with midpoint refinement near poorly
  supported components. This is a mesh-conditioning test, not a successful
  cartogram result. Existing frozen runs remain unchanged.

## 19:42–19:50 UTC — bounded mesh steps and combined border control

- Saved guide weight 8 and fixed-footprint border cost 16 with their matched
  country comparison. All ten test commands passed at checkpoint `23a95d8`,
  including the new four-test mesh suite. Logs are in `validation-1943`.
- Midpoint meshes give every component at least four supporting triangles, but
  the original optimizer still stops with 89–96% weighted area error. Mesh
  support alone does not solve the line-search problem.
- Added limited-memory BFGS with an Armijo search and a determinant-based step
  bound. The bound also rejects a direction that passes through a collapsed
  triangle and later returns to positive area. Five mesh tests pass.
- The 32-grid bounded solve finishes its four 2,000-iteration stages with 1.13%
  weighted area error, but a maximum component error of 97.7%. Every stage
  reaches its iteration limit. Geometry checks find no overlaps or changed
  hole counts. This is a useful guide experiment, not a converged cartogram.
- Inspected that continuous world image. China and India have less flat forms,
  but Russia, Central America, and parts of Southeast Asia have thin features.
  Started two exact-budget tile assignments from this guide. Also started longer
  32- and 64-grid solves with stronger initial distortion weights.
- Permitted existing region holes only in fixed-footprint boundary exchange
  mode. The occupied mask and each region's hole count must remain unchanged.
  This permits enclaves without claiming to fix existing empty holes. The
  42-test shape suite passes. Started a combined guide-8 and border-cost-16
  control from the better-shaped stretch-1.2 layout.
- The original 500,000-tile pipeline and old outline-cost control still run
  separately with their original code. No result is assumed from their runtime.

## 19:50–20:04 UTC — carry population sites through the mesh

- The combined guide-8 and border-cost-16 control retains 266 of 311 matched
  country borders, with 39 unsupported borders and 198 axis reversals. OWID has
  248, 48, and 210 respectively. Inspected the world image. Canada, Korea, and
  Pakistan still have poor shapes. These scores do not establish visual quality.
- Both tile assignments from the bounded 32-grid mesh have exact budgets and
  connected components. Inspected both world images. Korea and Southeast Asia
  remain misplaced. Neither result is suitable for production.
- Found a coordinate mismatch in the experiment design: native population sites
  had only a global scale and translation fit to the deformed geometry. Added
  piecewise affine site interpolation through the saved mesh. It checks the
  triangulation, triangle orientation, finite coordinates, and frame coverage.
- Added an explicit flow-coordinate site mode. It applies the same raster scale
  and stretch to geometry and sites, without a second global fit. All 481 world
  sites map inside the mesh frame. Six mesh tests and 20 partition tests pass.
- The transformed population mean is not the mean of all transformed population
  cells. This remains a site-placement approximation. Population totals and
  component labels do not change.
- Inspected the combined control's Europe, South Asia, and Indonesia details.
  Europe is more readable, but Italy is broad and Spain is rectangular. Shared
  island shapes remain poor. Saved the control and updated the gallery. All 16
  layout archives pass numeric and file-hash checks; 105 linked resources load.
- Inspected the long 64-grid mesh guide and the first and third 32-grid stages.
  The long guide has 2.20% weighted area error but 136% maximum component error.
  Its gradient stopping test passes. Russia and Central America are still thin.
  Earlier stages reduce some distortions but have larger area errors. They do
  not establish an acceptable mainland footprint.

## 20:04–20:09 UTC — reject transformed-site layouts; test mesh weights

- Inspected both transformed-site world layouts. Both have exact counts and
  connected components, but Korea remains misplaced. Taiwan moves to a poor
  position. Guide cost 8 has 61 missing and 78 unsupported component contacts,
  four region holes, and 319 direction reversals. Reject it as a replacement.
- Saved the continuous mesh controls and their stage images, numerical arrays,
  compressed geometry, solver records, and two transformed-site tile layouts.
  Inspected every saved continuous image. Lower area error still permits thin
  Russia and Central America. Earlier stages do not remove those defects.
- Added explicit water and density weights to the mesh objective. Defaults are
  unchanged. Started three 32-grid controls: water weight 0.001, source-area-only
  land weights, and their combination. These test whether the sea and dense
  land regions constrain low-density countries too much. No outcome is assumed.
- New stage records also save numerical mesh arrays, so intermediate sites can
  follow the same transformation as intermediate geometry. Seven mesh tests
  pass. Started a new ten-command validation checkpoint.

## 20:09–20:11 UTC — shared-island template control

- All ten commands passed at checkpoint `2591727`. Saved the logs and code hashes
  in `validation-2006`. Production code and targets remain unchanged.
- Added a separate shared-island control. It selects connected source land-border
  groups whose combined source area is at most 1% of the represented land-border
  area. This is a geometric rule, not a claim to classify every island.
- Each selected group gets a uniformly scaled geographic outline, exact local
  country quotas, and fragment repair without connector paths. The whole group
  is then translated clear of other land. Unselected components stay unchanged.
  This tests Ireland, Borneo, and other shared islands that singleton-island
  protection does not cover. It does not change the mainland deformation.
- The expanded 21-test partition suite passes. Tests check exact local budgets,
  connected components, whole-group placement, and unchanged unselected cells.
  World visual checks are still required.

## 20:11–20:15 UTC — inspect shared islands and mesh weight controls

- The shared-island control selects eight groups. Inspected its world, Europe,
  and Indonesia images. Borneo and Ireland have more geographic shapes than the
  flow versions. Counts remain exact, every component stays connected, and the
  component contact totals remain 59 missing and 55 unsupported contacts.
  Mainland cells are unchanged. Saved the result for review, not approval.
- Corrected the new mode's image caption and included its settings in saved
  review files. It is not a GridMapPipeline output.
- Inspected the final source-area-weighted mesh and the third stages of both
  low-water controls. Source-area weighting alone leaves thin features. Low
  water weight permits large rotations of Europe and Africa and bends Korea
  northward. Reject these inspected guides as production footprints.
- Added an optional polar-rotation cost to test that failure. It is explicitly
  separate from Sargent's published objective and is off by default. Analytic
  gradient, translation, and rotation tests pass. Started three 32-grid controls
  with rotation weights 2 or 10. Eight mesh tests pass.

## 20:15–20:25 UTC — resolution runs and component-wide shape prior

- Started the mainland-only flow, guide-8 partition, fixed-border control, and
  shared-island correction at 10,000, 110,000, and 500,000 tiles. Each resolution
  gets its own population sites and external flow solve. Envelope width scales
  with the square root of tile count. All three external flow solves pass.
  The new 500,000-tile run does not use the earlier failed guide.
- The 10,000-tile run finishes with exact counts, no split components, three
  region holes, and 81 missing plus 62 unsupported component contacts. Inspected
  its world image: the broad layout follows the 55,000-tile control, but Canada
  and Korea remain poor and small shapes lose detail. Higher-resolution runs
  are still in progress.
- Tested three blends of native population sites and flow-geometry centroids.
  Inspected all three final world images. More centroid weight moves Russia too
  far east; Canada and Korea do not improve enough. Reject these controls.
- Two low-water rotation trials stop at the determinant step floor with about
  95–96% weighted area error. Reduced the reciprocal-extension threshold from
  `1e-5` to `1e-12`, below the step floor, so the barrier remains active there.
  Tests pass; new controlled runs are in progress. The old failures are retained.
- Added an optional component-wide shape prior with free translation and fixed
  orientation. It compares transformed intersection centroids with uniformly
  scaled source centroids. It is not part of the cited paper's objective and is
  off by default. Nine mesh tests pass, including its analytic gradient. Started
  weight-1 and weight-10 controls. Coarse centroid samples remain a limitation.
- At 20:20 UTC, stopped the old 500,000-tile guide-only pipeline and stress-outline
  control. The cached 500,000-tile controls had already finished. The stress run
  still reported 79 split regions after 925 swaps. Neither cancelled run has a
  completed final result. Saved cancellation records in the job directory.

## 20:25–20:35 UTC — validation and softer guide controls

- All ten commands pass at checkpoint `99bb0c7`, with nine mesh tests and
  21 partition tests. Saved logs and hashes in `validation-2027`.
- Inspected the final corrected-barrier rotation-2 guide and the third stages of
  the component-shape controls at weights 1 and 10. Rotation control reduces
  large continent turns, but thin Russia and Central America remain. Shape
  weights 1 and 10 do not correct the visual defects. Started weights 100 and
  1000 to test a stronger component prior before rejecting that direction.
- Started two overlapping source-shape guides with collision weights 0.1 and 1.
  They omit the final rigid collision-separation pass that can reopen gaps.
  Overlap is permitted only in these intermediate guides. The later capacity
  assignment must still have exact counts and no overlap. These are spring
  placement controls, not continuous cartograms or production maps.
- Saved the new 10,000-tile result after world, Europe, and Indonesia checks.
  The 110,000- and 500,000-tile partitions are still running. All three external
  flow solves passed before their tile assignments started.

## 20:35–20:51 UTC — Japan feedback and a joint island-placement test

- The user identified a missed defect: South Korea separates parts of Japan in
  the leading 55,000- and 10,000-tile layouts. Keep those layouts as leading
  controls, but do not treat their island placement as correct.
- Traced the 55,000-tile defect to Kyushu. Its 81 tiles are anchored to Honshu,
  but independent collision removal shifts them about nine tiles from the desired
  coast position, to the west of South Korea. Honshu stays fixed under the old
  large-island population threshold. Counts and connectivity checks miss this.
- Added a separate nearby-archipelago control. It uses nearest larger source
  components and a source-gap threshold, not country identity. Rebuild nearby
  island positions without foreign obstacles, then translate the whole group.
  Separate islands remain separate; no connector cells are added.
- The group placement retains definite source longitude and latitude box
  separations from nearby land. This prevents a local collision search from
  choosing the wrong side of South Korea. Conflicting or blocked groups remain
  unchanged and are reported. Mainland cells and every tile shape stay fixed.
- Added bounded integer translations and a synthetic case with an island on the
  wrong side of a mainland. The 43-test shape suite and 22-test partition suite
  pass. World images are the next check; no visual improvement is assumed yet.
- Completed the recorded-pipeline integration for mainland-only flow, optional
  fixed-footprint border changes, and shared-island templates. Its headless tests
  also check partial-guide labels and reject missing mainland components.
- Strong centroid-only mesh priors show thin features between samples. Replaced
  those samples with exact polygon means and second moments, including holes.
  Ten mesh tests pass. New weight-100 and weight-1000 controls are running.

## 20:54–21:00 UTC — Japan review and displacement limit

- Visually checked both new world maps and dedicated Japan–Korea details.
  The main Japanese islands no longer lie on opposite sides of South Korea.
  Mainland cells, tile counts, and land contacts do not change.
- The first rule is not suitable for general use. At 10,000 tiles it moves
  Java and Sumatra too far south and east. At 55,000 tiles, some Philippine
  islands also move too far. Keep these controls separate from the leading maps.
- Added a maximum group translation of twice the square root of the group tile
  count. This is a safety limit, not a geographic accuracy test. A rejected group
  keeps all its original cells. The report gives its proposed move and limit.
- Added the Japan–Korea view to regional reviews. The 22 partition tests pass,
  including a check that a rejected group remains unchanged. New bounded world
  controls are next; their quality is not yet known.

## 21:00 UTC — Bounded island controls saved

- Visually checked the bounded 10,000- and 55,000-tile world images. Japan keeps
  the corrected placement. The large Java–Sumatra displacement is rejected in
  the coarse map. The mainland footprint is unchanged at both resolutions.
- Saved separate `archipelago-10000` and `archipelago-55000` review bundles,
  including cells, input contacts, placement records, hashes, and Japan details.
  Added links to the gallery. The leading controls remain unchanged.
- The 110,000-tile mainland pipeline finished at 20:39:55 UTC. Its images still
  need visual review. The 500,000-tile run is still in progress.

## Method reference

The [SciPy closing documentation](https://docs.scipy.org/doc/scipy-1.17.0/reference/generated/scipy.ndimage.binary_closing.html)
defines closing as dilation followed by erosion. It fills gaps smaller than the
structuring element. Read the source documentation directly. This definition
supports the diagnostic implementation, not the claim that each marked gap is
artificial. Padding prevents the image edge from eroding the displayed land.
