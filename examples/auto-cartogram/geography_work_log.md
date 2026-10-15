# Geographic relationships: work log

## 2026-10-15: baseline checks

Keep the current 55,000-tile layout and its population export unchanged.
Test general rules. Do not add position rules for named countries.

Added `review_geography.py`. It measures tile edges beside exterior water and
beside enclosed water. Exterior water must have a four-neighbour path to the
outer frame. A diagonal opening does not qualify. It also checks the four
nearest source components for each represented component. It reports source
box separations that the tile boxes no longer preserve.

The first all-pairs geometry search exceeded its 180-second limit. Replaced it
with a spatial index and an expanding distance query. The complete check then
finished within the same limit. Five unit tests pass.

Baseline results:

- 1,315 nearby component pairs; 180 pairs have lost a source box separation.
- 60 components have no edge beside exterior water.
- Estonia, Latvia, and Lithuania each have zero exterior-water edges.
- Paraguay has eight exterior-water edges.

These counts are measurements, not a quality score. Real landlocked components
must have no ocean access. Enclosed water can be a lake or a defect. Source box
separation can be too strict for distorted shapes. Equal Earth distance is not
geodesic distance, and the antimeridian needs separate care.

Reports and input hashes:
`output/auto-cartogram/geography-baseline-55000/`.

## Placement rule review

`place_islands.py` selects one nearest eligible coast and places islands in
population order. It maps a source coast point onto the resized tile shape.
This does not preserve the island's position against several neighbours.
A change in the anchor shape can move an island even with no packing conflict.
This is a mechanism to test, not yet a confirmed cause for every reported case.

`restore_archipelagos.py` adds nearby groups and axis constraints. It does not
preserve the full set of regional coast relationships. It keeps components
with land borders fixed, which can restrict shared islands.

## Next experiments

1. Derive source coastal access from the full source geometry. Include
   components with no tiles. Compare source access with tile water access.
2. Represent important sea passages explicitly during mainland placement.
   Keep passages open without adding thin land paths or large empty gaps.
   Do not treat all water as a defect to fill.
3. Derive island targets from several nearby coast points. Fit local position
   changes from source geometry to the mainland layout. Place nearby islands
   together, then check collisions and relative order.
4. Check whether Manhattan and Long Island have separate represented groups
   before treating their positions as independent variables.
5. Compare world and regional images with the unchanged baseline. Check the
   Baltic, Paraguay, Ireland, New York, Indonesia, and Japan. Retain exact tile
   budgets, separate island populations, and the existing Japan correction.

No placement rule has changed in this first step.
