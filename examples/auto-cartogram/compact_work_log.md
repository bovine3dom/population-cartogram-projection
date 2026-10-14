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

## Method reference

The [SciPy closing documentation](https://docs.scipy.org/doc/scipy-1.17.0/reference/generated/scipy.ndimage.binary_closing.html)
defines closing as dilation followed by erosion. It fills gaps smaller than the
structuring element. Read the source documentation directly. This definition
supports the diagnostic implementation, not the claim that each marked gap is
artificial. Padding prevents the image edge from eroding the displayed land.
