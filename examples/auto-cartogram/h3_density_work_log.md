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

## 23:14 UTC: label and format checks

The city preflight matches 12,154 of 12,341 places to a component/H3 source.
There are 186 points outside the source polygons and one point with no source
fragment. Do not move these labels to a different island. Jakarta and Surabaya
match Java; Denpasar matches Bali; Makassar matches Sulawesi. Tokyo and Osaka
match Honshu; Sapporo matches Hokkaido; Naha matches Okinawa.

H3-MON expects a two-unit tile step. Apply `x = 2 * layout_x` and
`y = -2 * layout_y` in the export. This avoids overlapping cells and incorrect
border detection. The source layout and transport coordinates stay unchanged.
The H3-MON colour scale is `quantile`; the app has no `log` scale option.

The 28 geometry tests also pass. The fit is still running on China.

## 23:42 UTC: export and visual review complete

All 481 fits and balance checks passed. Total solver time was 1,825.7 seconds.
475 groups kept their original sparse support. Six groups needed one rook step:
mainland China, Morocco, New Zealand's North Island, one Brunei component,
Corsica, and one Malaysian component. No group needed two or more steps.
No population crosses a group boundary. The exporter also rejects group
assignments that cross countries.

Published files are in:
`/home/olie/projects/H3-MON/www/data/planet-auto-55000-h3-5-islands/`.
The H3-MON app and its default data remain unchanged. The local server listens
on port 1983. Open:

<http://localhost:1983/?data=planet-auto-55000-h3-5-islands/population_density_hilo.arrow&cartogram=planet-auto-55000-h3-5-islands/cartogram_weights_auto_55000_h3_5_hilo.arrow#x=0&y=15&z=0>

The export has 388,513 unique H3 parents and 1,022,504 transport rows.
Independent Arrow read-back confirms exactly 55,000 occupied tiles, with only
the recorded coordinate conversion. Maximum parent weight-sum error is
1.12e-15; maximum tile weight-sum error is 1.98e-14. All density values match
population divided by actual H3 area. Every placed city remains in its group.
Maximum relative target-population error within a group is below 0.0001.

The first visual review found excessive city-name lists and nearly all-yellow
cartogram colours. Keep only the largest city label per tile, but retain all
city candidates in the audit. Use the cartogram distribution for colour
quantiles. There are now 9,202 labelled tiles from 12,154 matched city points.
The other 187 points have explicit unmatched reasons.

Reviewed the world, Japan, western and central Indonesia, and Europe in the
real H3-MON app. Jakarta, Denpasar, and Makassar remain on their own islands.
Tokyo, Osaka, Sapporo, and Naha remain on their own islands. The Japan correction
is retained. London, Paris, Madrid, and Rome show distinct density peaks.
India still has strong internal distortion. Northern European outlines and
Korea remain compressed. This mapping does not approve the layout for production.

Headless Chromium reports no page errors or failed requests. The geographic
pane uses a neutral local style; external base-map tiles are not part of this
test. The screenshot runner uses normal pane controls, zoom, and drag gestures.

Review page and saved checks:
`results/compact-landmass/fixed-coasts-55000-density/index.html`.
Full fragment-level checks remain in the output directory and in the export's
`export-checks.json`. The source groups and city audit are included with the
Arrow files. The original layout, production source, and OWID CSV are unchanged.

To repeat the browser check with the local H3-MON server running:

```sh
node examples/auto-cartogram/review_h3_mon.mjs \
  /home/olie/projects/H3-MON \
  output/auto-cartogram/world-55000-h3-5-density
```

All two export tests, six transport tests, and 28 geometry tests pass.

## Tests before the first commit

- `test/auto_transport.py`: six tests pass.
- `test/auto_h3_export.py`: two tests pass. These check a shared H3 parent across
  two island groups, separate city labels, population weights, Arrow types,
  screen coordinates, corrupt input, and repeated within-group expansion.
