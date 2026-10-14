# Population sites for layout guides

A country's geometric centre can be far from most of its population. Russia's
main geographic component is a useful example. Its native-population site is
near 52 degrees east. Its polygon centroid in longitude and latitude is near
99 degrees east. These are different measurements, not a projection-error test.

The `population_sites.py` experiment computes one site for each existing
population group. It does not change groups, counts, source boundaries, or the
transport solver. It does not join overseas components by country identity.

## Method

1. Join matched native sources to native H3 centres by cell ID, not row order.
2. Check that IDs are unique and population values agree.
3. Use the existing component-to-group mapping from `groups.csv`.
4. Compute a population-weighted mean of unit vectors on the sphere. This avoids
   a longitude-average error at the date line. Reject a near-zero mean vector.
5. Project each resulting site to Equal Earth coordinates with radius 1.
6. Check that group population totals match the prepared input.

Each H3 cell places its population at its centre. A group's site need not lie
inside its outline. The source population year remains unspecified.

The 55,000-tile input uses 32,668,501 matched native source cells and a population
of 7,954,677,990. The unmatched source population is not added to these sites.
The [saved sites and source hashes](results/compact-landmass/population-sites/sites.json)
record the input scope. The [CSV](results/compact-landmass/population-sites/sites.csv)
contains geographic and projected coordinates.

## Run

Use the prepared files from the earlier source audit:

```sh
p=output/auto-cartogram
"$p/geometry-env/bin/python" examples/auto-cartogram/population_sites.py \
  "$p/world-55000-dissolved-input" \
  "$p/world-transport-sources/sources.arrow" \
  "$p/world-centres/centres.arrow" \
  "$p/world-55000-population-sites"
```

Use a new output directory. The native tables are large. The code checks all
source IDs and population totals before it writes the sites.

Pass the saved CSV to `partition_land.py --sites FILE`. This aligns the sites
to the starting layout by translation and positive uniform scale. With
`--flow-geometry FILE`, it instead aligns them to the flow raster. There is no
rotation or reflection. The output records the alignment and file hashes.

`--float-islands` prevents isolated island cells from reserving holes inside the
mainland target. After country assignment, it translates intact islands to free
space near their fitted guide sites, with a one-cell side-neighbour gap. If no
guide sites exist, it uses the starting centres. Earlier trials used starting
centres even when fitted sites existed. A later island-placement stage can
refine their positions. This does not guarantee correct island order.

## Results and limits

Rigid placement at these sites is rejected. Collision removal changes country
order. The first global partition improves Russia's westward position, but
separates South America, misplaces Japan, and leaves large holes. It also has
three split regions. Better sites alone cannot repair a poor land footprint.

Further controls combine population sites with a shared flow footprint and
movable islands. Inspect their images before selecting any result. Site
accuracy, exact counts, low gap scores, and connected regions are separate
checks; none is sufficient on its own.
