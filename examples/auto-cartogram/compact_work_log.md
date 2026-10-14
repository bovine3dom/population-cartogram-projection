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

## Method reference

The [SciPy closing documentation](https://docs.scipy.org/doc/scipy-1.17.0/reference/generated/scipy.ndimage.binary_closing.html)
defines closing as dilation followed by erosion. It fills gaps smaller than the
structuring element. Read the source documentation directly. This definition
supports the diagnostic implementation, not the claim that each marked gap is
artificial. Padding prevents the image edge from eroding the displayed land.
