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

## Method reference

The [SciPy closing documentation](https://docs.scipy.org/doc/scipy-1.17.0/reference/generated/scipy.ndimage.binary_closing.html)
defines closing as dilation followed by erosion. It fills gaps smaller than the
structuring element. Read the source documentation directly. This definition
supports the diagnostic implementation, not the claim that each marked gap is
artificial. Padding prevents the image edge from eroding the displayed land.
