# OWID landmass-first world trial

[Open the review](http://proto.olie.science:8642/results/owid-landmass-world/index.html).

This is a separate trial. The default map and H3-MON exports are unchanged.

## Result

The pipeline finds all 130 connected landmasses in the original OWID artwork.
There is no list of special countries or islands in the fit code.

| Result | Landmasses |
| --- | ---: |
| Original shape retained because all part budgets are unchanged | 61 |
| Single-part outline resized | 63 |
| Shared outline resized and internal borders fitted | 4 |
| Previous layout retained within the outline bound | 2 |

The four shared islands are Borneo, New Guinea, Ireland, and Timor. The two
retained landmasses are Europe–Asia and North America.

- All 286 target parts meet their tile budgets and remain connected.
- All existing part contacts remain. No new land contact is added.
- The map has 54,967 unique land tiles.
- All 208 country-label totals match the normalized original OWID input.
- The 64 empty cells inside individual landmasses remain empty.
- Separate landmasses have at least a one-cell gap, including diagonals.
- The largest centre displacement from the previous trial is 1.69 cells on
  one axis, rounded up. Philippine spacing remains intact.
- All 390 Python regression tests pass.

## Fixed reference and budgets

`data/cartogram.csv` supplies the shapes. Duplicate coordinates use the audit
last-row rule. This converts 54,978 input rows to 54,967 unique land cells.

`output/auto-cartogram/owid-borneo-outline-v1` supplies the exact part budgets
and desired positions. It does not supply new outline guides. Population
assignments are copied without change. Automatic source identities still need
review. This run does not improve those assignments or create new target
islands for source components that have no target tiles.

The reference correction matters for Borneo. Original OWID has 416 tiles on
that island. The earlier Borneo experiment used a partly resized, 286-tile
outline. Both trials produce 166 tiles, but this trial scales the original
416-tile shape. The review shows all three layouts at the same scale.

## Method

1. Find connected landmasses without using country boundaries as barriers.
2. Add the requested part budgets for each landmass.
3. Make an exact-count outline from the original combined shape.
4. Fit the internal borders while keeping counts, connectivity, contacts,
   and coastal or inland status.
5. Place the completed landmasses as whole pieces. Do not rotate them.
6. Check the complete world before writing a layout export.

The border solver uses candidate labels near each transformed country part.
A maximum-flow check detects both individual and collective budget shortages.
It widens the search only for the affected labels. Connectivity cuts reject
split parts without fixing them to old root cells.

Internal water and its shores are protected when a landmass with holes changes
size. Small coast gaps near several parts are also protected in that step.
This avoids closing narrow gaps through grid rounding.

The original artwork has another 108 enclosed empty cells between separate
landmasses. These gaps can move or open to the sea. They are not assigned to
countries. This is an artwork policy, not a geographic lake classification.
It does not add lakes missing from the original artwork.

### Bounded reuse

An exact outer outline can cause unnecessary internal border changes. Before
fitting a changed shared landmass, the pipeline checks the previous layout
against the new reference guide. It can retain that layout only if all hard
checks pass and the outline difference is within the bound.

The bound is 1% of the landmass tile count, rounded down, with a two-cell floor
for grid rounding. Difference means the symmetric difference of occupied
cells, before final rigid placement. A relocated tile contributes two cells
when it leaves one position and enters another.

| Landmass | Difference from guide | Fraction of land area |
| --- | ---: | ---: |
| Europe–Asia | 284 cells | 0.864% |
| North America | 2 cells | 0.0525% |

These two layouts were validated and retained, not newly fitted. All other
landmasses use their generated outlines exactly. No budget, border, or water
check is relaxed by this rule.

If the fixed-outline search fails and no previous layout passes the bound,
a local fit can use the scaled outline as a soft guide. Its result must still
pass the same bound and hard checks. This fallback was not needed in the
published run. A blocked fit prevents a complete export. Set
`--outline-tolerance 0` to disable reuse and coastline relaxation.

## Work log: 2026-10-18 UTC

- Built automatic landmass discovery from the original artwork.
- Added the sparse internal-border solver and budget-capacity checks.
- Removed fixed connectivity roots after tests showed that a part may need
  to move away from its old position.
- Early strict world trials failed on Europe–Asia. Wider search regions and
  coast-gap guards did not resolve that case within the tested search.
  This is not proof that an exact fit is impossible.
- A local fallback fitted Italy, but the Turkey step reached its time limit
  without a valid solution. That incomplete trial was not published.
- Validated the existing Europe–Asia fit against the 1% bound. It passed.
- Visually reviewed trial v12. Its exact North American outline moved several
  Central American borders to accommodate a one-tile reduction in the US.
  Added bounded reuse before fitting to avoid this unnecessary change.
- Completed v13, v15, and v16. Their land-cell files are identical. Published v16.
- Visually checked the world, the four refitted shared islands, the North
  American comparison, the Malaysian peninsula, Britain, US parts, and the
  Philippines. The previous Philippine spacing remains intact.
- Small internal borders still need visual judgement. Brunei's four tiles
  form a T shape, and the New Guinea border has small steps. The combined
  island outlines are preserved, but this is not production approval.
- Added a test to ensure that a lake shore does not permit a new sea coast.
- Ran all 390 Python tests. Separately checked all original country totals.
  The review URL returned HTTP 200.

## Repeat

Run from the repository root. Use new output directories.

```sh
PY=output/auto-cartogram/geometry-env/bin/python
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 "$PY" \
  examples/auto-cartogram/owid_landmass_world.py \
  data/cartogram.csv output/auto-cartogram/owid-borneo-outline-v1 \
  output/auto-cartogram/owid-landmass-world-repeat --seconds 90

"$PY" examples/auto-cartogram/review_owid_landmasses.py \
  data/cartogram.csv output/auto-cartogram/owid-borneo-outline-v1 \
  output/auto-cartogram/owid-landmass-world-repeat \
  output/auto-cartogram/owid-landmass-world-review-repeat
```

`landmass-world.json` records every landmass, input hashes, solver results,
outline bounds, and translations. The published compressed CSV files contain
the exact reviewed layout. The parent population tables remain available in
the review directory.
