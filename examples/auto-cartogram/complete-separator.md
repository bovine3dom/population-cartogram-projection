# Complete cuts before population fitting

## Result

The 18-cut experiment gives a useful release of the Kazakhstan-area pinch.
It is a review candidate, not a new current best.

- [55,000-tile map](results/geography/complete-separator/planet-three-block-p90-200-islands/review.png)
- [Comparisons, cut lists, and checks](results/geography/complete-separator/index.html)

The tile outline errors decrease by approximately 12% for Russia, 31% for
China, and 8% for India. Kazakhstan's error increases by approximately 7%.
These scores compare area-aligned and centre-aligned outlines without rotation.
They do not measure all geographic relationships. The
[OWID reference excerpt](results/geography/kazakhstan-scoped/owid.png) places
Russia far from China but retains a China–India contact. Our three-domain
method needs more cuts. The excerpt omits other countries; not all its empty
space is sea.

All 55,000 country tiles remain. All 481 components stay connected. The map has
45 named lakes in 220 empty cells. Lakes do not use country tiles.
All 18 selected cuts remain open. Against the same retained-border policy,
missing borders decrease from 65 to 50. False geographic contacts decrease
from 48 to 27.

## Why this changes the shapes

The earlier four cuts did not split the retained border graph. Routes remained
through North Korea and the Caucasus. A shared population flow still coupled
the regions, even when source strips were removed.

The new method first splits that graph. It then fits three connected land groups
with the saved Kontur population patches. Each group retains its internal
borders. Whole-group translations assemble the results. No source land or
population is removed. The tile, island, and empty-lake stages use a separate
contact file that excludes the selected cuts.

This is not the earlier method that fitted each country separately. Before the
tile stage, all 275 uncut regional contacts remain.

## Policy cost

A complete separator is not possible under the original density limits:
mean 20 and segment p90 50 people/km². The candidate permits mean 75 and p90 200.
A separate short-border rule permits at most 50 km and at most 500,000 people
in the audited corridor.

Five selected borders fail the original rule:

- Russia–Azerbaijan
- Russia–North Korea
- China–Myanmar
- Laos–Myanmar
- Myanmar–Thailand

The sum of corridor populations is 14,847,167. This is not a count of unique
people; corridors can overlap. This policy needs review before production use.
A stricter p90 limit of 150 selects 21 cuts with a larger total corridor cost.

## Remaining defects

Britain is too far south. Nordic shapes still need work. Kazakhstan and
Mongolia remain difficult at this tile resolution. Some false and missing
borders remain. The count of enclosed non-lake water increases, but large
regions include the Baltic Sea and Red Sea; this is not a phantom-hole count.

One 21-cut preview placed Japan on the wrong side of Korea. The island rule
found the correct position but rejected the required movement as too large.
An optional general repair now allows the minimum movement needed to satisfy
source separation, then applies the usual limit to extra movement. It has no
country-specific exception. The 18-cut preview already placed Japan correctly.

## Reproduce the main stages

Use the geometry Python environment and a new output directory for each run.

```sh
PY=output/auto-cartogram/geometry-env/bin/python
ROOT=output/auto-cartogram
CODE=examples/auto-cartogram

$PY $CODE/block_cut_flow.py $ROOT $ROOT/new-block-flow \
  --grid 512 --split-india --mean-limit 75 --p90-limit 200
$PY $CODE/assemble_block_world.py $ROOT $ROOT/new-block-flow $ROOT/new-block-world
$PY $CODE/run_kontur_planet.py $ROOT/new-block-planet \
  --guide $ROOT/new-block-world/guide.geojson \
  --guide-record $ROOT/new-block-world/guide-record.json \
  --inputs $ROOT/new-block-world/inputs
$PY $CODE/refine_block_islands.py $ROOT/new-block-planet \
  $ROOT/new-block-world/inputs $ROOT/new-block-islands
```

Solver repeats can vary. One run stopped because a Norway patch became invalid.
Do not use failed output. Check the saved hashes, actual areas, contacts, and
images for each run. Current best and all H3-MON exports are unchanged.
