# Large regional separation

## Purpose

The small-gap tests did not test the requested layout change. Their negative
results apply to local moves, not to large regional moves. This experiment
allows Russia and China to occupy separate parts of the map. It does not use
rules for named countries. The published H3-MON map is unchanged.

[Review images](results/geography/regional-release/index.html)

## Method

`release_regions.py` uses population in a 25 km corridor on each side of a
source border as an edge weight. It forms regional groups with weighted
modularity. It uses one global weight scale. Separate calculations for each
connected source network split South America too much in the first test.

See the [NetworkX method documentation](https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.community.modularity_max.greedy_modularity_communities.html).
Resolution controls group size. This method finds population-linked groups;
it does not prove that a border is safe to remove.

All shores of each named lake must move together. Independent island
components within 200 km form chains. Each chain selects one nearby source
coast, with a 500 km limit. Distances use the Equal Earth plane. They are
approximate, not geodesic. No country ID controls an island attachment.

A uniform world scale maps source population centres to tile centres. The
spacing setting multiplies that scale. Each region moves as a rigid shape.
There is no old-centre anchor and no maximum gap. Large regions move first.
Packing preserves broad source-centre axis order and reserves one empty cell
between groups. The packing search has a 256-cell radius around each target
translation. This numerical limit is not a limit on movement from the input.
If packing cannot meet the order constraints, the run fails.

Every component keeps its tile count and shape. Lakes move with their shores
and remain empty. Internal contacts stay intact. No new false contact is
permitted during translation. Reports list lost true contacts, including
contacts that fail the earlier sparse-border test.

**This is a broader experiment than permission to remove only sparse borders.**
Hard protection of all other borders still links Russia and China through
chains of countries. The current grouping can remove populated borders too.
That is a known cost, not a hidden exception.

## Results and visual review

The successful global tests use 65 regional groups. Each loses 40 existing
true contacts; 20 fail the earlier sparse-border test. All keep 55,000 land
tiles, 481 connected components, and 220 empty cells in 45 named lakes.
Missing contacts increase from 63 to 103. False contacts decrease from 34 to
13. These totals use the same administrative contact reference as before.

At spacing 1.1, mainland Russia and China are 41.62 tile spacings apart.
At spacing 1.3, they are 48.10 apart. The input distance was 1.00. These are
nearest tile-centre distances between the largest components, not kilometres.
Blank gaps are not geographic seas.

A further 150 rounds of shape refinement start from spacing 1.3. They protect
all true contacts that remain after translation. They do not restore the
removed contacts. Tile-weighted outline error falls from 0.42690 to 0.40372,
about 5.4%. This is an aligned outline score, not a geographic accuracy score.
The refined layout has 101 missing and eight false contacts. It creates six
new enclosed empty cells. Translation alone does not improve outline error.

Visual checks covered world views and details of Eurasia, Africa, and
Indonesia. Russia now sits beside Europe, separate from China. Japan stays
together beside Korea. The empty African lakes remain visible. However, West
Africa separates too far from East and Southern Africa. Spacing 1.8 adds too
much ocean space. Moving island chains intact also retains some old placement
errors, including Java's position. These maps are not approved replacements.

Coarser grouping at resolution 0.5 failed the packing constraints at spacing
1.1 and 1.3. The failed runs produced no complete layout. More local shape
iterations will not fix this placement limitation.

## Next test

Replace greedy rigid placement with joint regional placement. Charge for the
population affected by each lost border and for errors in nearby coast
relationships. Reward shape improvement, rather than separation by itself.
Compare the result with OWID and the lake baseline at the same display scale.
Use the current experiment as evidence that large moves are possible, not as
an approved choice of borders to remove.

## Reproduce

Run from the repository root. Use the geometry environment with the existing
population sources and border audit. Use a new output path for each run.

```sh
PY=output/auto-cartogram/geometry-env/bin/python
$PY examples/auto-cartogram/release_regions.py \
  output/auto-cartogram/world-55000-dissolved-input \
  output/auto-cartogram/geography-margin1-lake-vacancies-final \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  output/auto-cartogram/world-55000-h3-5-density/sources.csv \
  output/auto-cartogram/sparse-border-audit-25-wide/border-population.json \
  output/auto-cartogram/regional-release-reproduce \
  --spacing 1.3 --resolution 1
$PY examples/auto-cartogram/relax_sparse_borders.py \
  output/auto-cartogram/world-55000-dissolved-input \
  output/auto-cartogram/regional-release-reproduce \
  output/auto-cartogram/sparse-border-audit-25-wide/border-population.json \
  output/auto-cartogram/regional-release-reproduce-refined \
  --rounds 150 --guide 16 --gap-cost 16 --preserve-all
PYTHONDONTWRITEBYTECODE=1 $PY -m unittest discover -s test -p 'auto_*.py'
```

All 187 tests pass. Five new tests cover lake grouping, independent groups,
frame fitting, and exact rigid translation. Release reports record input and
script hashes, settings, island attachments, lost borders, and packing shifts.
