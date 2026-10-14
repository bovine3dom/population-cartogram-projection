# H3-5 density on the 55,000-tile layout

## 2026-10-14, 23:05 UTC: run started

Use `results/compact-landmass/fixed-coasts-55000`. This layout includes the Japan
correction. Do not use the rejected shared-position layout. Do not change the
production map.

- Layout: 55,000 tiles and 481 transport groups.
- Matched population: 7,954,677,990.
- Population on small components with no tile: 10,133,200. These components
  retain the explicit group in `groups.csv`. This is not whole-country pooling.
- Excluded native population: 77,246,034. The source population year is not
  verified.
- Sources: 400,545 component/H3-5 fragments. The cached source file hash matches
  its saved independent check: `ccaf1c76e6d2257026ff04df307e83298f0b483175e65130d08acebcbdea47cd`.
- Cell file hash: `9f0c734b0fab4f18e732dbed9339863b7662a46b46478f0520e31156bcb5be7a`.

The source cache has a 10,000-tile run name. Its component populations are
independent of that layout. The new fit replaces the old group assignments
with the 55,000-tile assignments and checks every component population.

Use the public transport solver with the oneAPI backend, one group at a time.
Save each raw group before starting the next group. Then balance source and
target populations. If sparse support is insufficient, add up to four rook
steps inside the same group. Never add support across a group boundary. The
maximum permitted relative target error is 0.0001. This test does not prove
spatial quality.

India completed in 345.9 seconds and passed the balance check. China is running.
The full export is not yet available.

## Export method

Keep each component/H3 fragment separate until after transport. For H3-MON,
combine fragments only at the same H3 parent and target tile. Divide transported
mass by parent population for `weight`, and by tile population for
`weight_mean`. Both sets of weights must sum to one on their respective axes.

Density is matched parent population divided by its actual H3 cell area in
square kilometres. Parent density is shared across fragments of that parent.
This is a limit of H3-5 resolution, not a transfer between island groups.

Use GeoNames cities with more than 50,000 people. Match the city point to one
source polygon. Place its label on the largest transport contribution from its
component/H3 fragment. Do not use a country-wide fallback. Save unmatched city
points with reasons. Use native H3-8 to H3-5 parents for both population and
cities. [H3 documentation](https://h3geo.org/docs/highlights/indexing/) states
that logical containment is exact but geographic containment is approximate.
Use [actual cell area](https://h3geo.org/docs/api/misc/) rather than average area.

## Run commands

Run from the repository root. The main checkout has the functional oneAPI
environment. The fit script includes the core code from this worktree.

```sh
OUT=output/auto-cartogram/world-55000-h3-5-density
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
OPENBLAS_NUM_THREADS=4 julia --threads=8 \
  --project=/home/olie/projects/population-cartogram-projection/examples/uk-h3 \
  examples/auto-cartogram/fit_h3_groups.jl \
  output/auto-cartogram/world-10000-transport-r5-grouped/sources.csv \
  "$OUT/groups.csv" "$OUT/layout/cells.csv" "$OUT"

OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
output/auto-cartogram/geometry-env/bin/python \
  examples/auto-cartogram/balance_h3_groups.py "$OUT" --wait

julia --project=examples/auto-cartogram \
  examples/auto-cartogram/prepare_h3_labels.jl \
  output/auto-cartogram/world-10000-transport-r5-grouped/sources.csv \
  /home/olie/projects/population-cartogram-projection/output/germany-h3-res7/cities15000.tsv \
  "$OUT/labels"

output/auto-cartogram/geometry-env/bin/python \
  examples/auto-cartogram/export_h3_groups.py "$OUT" \
  output/auto-cartogram/world-dissolved/polygons.geojson \
  /usr/share/iso-codes/json/iso_3166-1.json \
  /home/olie/projects/H3-MON/www/data/planet-auto-55000-h3-5-islands
```

The label and export commands refuse to overwrite existing output. The fit
resumes complete raw shards only when input hashes match. Keep the original
source, target, and script files for a restart.

## Tests before the first commit

- `test/auto_transport.py`: six tests pass.
- `test/auto_h3_export.py`: two tests pass. These check a shared H3 parent across
  two island groups, separate city labels, population weights, Arrow types,
  screen coordinates, corrupt input, and repeated within-group expansion.
