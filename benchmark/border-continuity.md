# Border continuity: global mapping audit

## Input and scope

This audit uses the existing global file, not the new UK or Germany fits:

`~/projects/H3-MON/www/data/cartogram_weights_hilo.arrow`

SHA-256:
`af126bbd70747c95d2921f5d63a81fed4b5f9aebde98e3b12db7628d40a49249`

The file contains 894,784 rows, 387,294 distinct H3-5 source cells, and 54,931
cartogram cells. The cartogram grid step is 2 on both axes. Eleven target cells
contain both South African and Lesotho sources. The seam audit excludes these
mixed cells; it does not treat them as data errors.

No population fit was run. The input files and H3-MON application were not
changed. This audit does not establish which historical solver settings caused
the observed patterns.

## Method

For each target cell, calculate the source geographic centre from `weight_mean`.
Use a weighted mean of unit vectors on the sphere, then normalize that mean.
Measure great-circle distance between the centres of side-adjacent target cells.
Call this distance a jump. Also measure the weighted mean distance of source
centres from each target centre, to check source spread.

A jump is a diagnostic, not an error bound or a mapped line segment. Unequal
geographic distances are expected in a population cartogram. The aim is not to
make all adjacent centres coincide. Country size and population distribution
also affect the comparison between internal edges and international seams.

For selected horizontal and vertical lines, use H3-MON's actual `strokeCoverage`
and `projectStroke` functions. These use source-normalized `weight`, not
`weight_mean`. Export the resulting source scores to GeoJSON. The plots show
these scores and, separately, the target centres in line order.

## Measurements

| Side-adjacent cell pairs | Count | Median jump | 90th percentile |
| --- | ---: | ---: | ---: |
| Same country | 102,415 | 23 km | 92 km |
| Different countries | 3,699 | 314 km | 1,405 km |

Across all included target cells, median source spread is 9 km. Its 90th
percentile is 29 km. Some cells have much greater spread.

| Country seam | Cell pairs | Median jump | Maximum jump |
| --- | ---: | ---: | ---: |
| France–Germany | 5 | 50 km | 86 km |
| Germany–Poland | 22 | 100 km | 324 km |
| Finland–Russia | 10 | 274 km | 488 km |
| India–Pakistan | 130 | 291 km | 443 km |
| Canada–United States | 73 | 677 km | 2,182 km |

The global file uses code 249 for metropolitan France. Do not assume that all
country codes in this older file match the new extract workflow.

### Selected straight lines

- Germany–Poland, `(484,172)` to `(506,172)`: the representative seam jump is
  100 km. The footprint is one connected H3 component at score thresholds 0.01
  and 0.1. A jump between centres does not necessarily mean a broken footprint.
- Finland–Russia, `(504,136)` to `(526,136)`: the seam moves from about
  `(62.36 N, 28.45 E)` to `(60.04 N, 30.21 E)`, a 274 km jump. The footprint
  changes direction towards the Saint Petersburg area. The full line also
  includes a Swedish cell and a blank cartogram cell.
- Canada–United States, `(92,258)` to `(92,276)`: the selected seam jump is
  677 km. The footprint has many disconnected components. Sparse populated
  source coverage is one reason why a continuous centre path is not a sufficient
  quality test.
- Inside Russia, `(580,230)` to `(592,230)`: adjacent targets `(590,230)` and
  `(592,230)` represent centres near `(44.93 N, 44.12 E)` and
  `(47.00 N, 142.45 E)`. Their separation is 7,059 km. Their source spreads are
  only 42 km and 35 km. This large jump is not just an average of broad source
  distributions, and it does not cross a country border.

### Cartogram adjacency is not geographic adjacency

Russia and Sweden share two side-adjacent cell pairs in this cartogram.
They do not share a geographic land border.

Russia has no side-adjacent cells with China, Kazakhstan, or Mongolia. The
nearest target-centre distances are approximately 104, 28, and 173 grid-cell
widths, respectively. These are distances through the layout, not counts of
empty cells. A border penalty cannot create these missing seams.

## Cheap one-way experiment

Keep one country's mapping fixed. In the other country, select cells at the
shared seam and two interior layers. Exclude cells that touch a third country.
Try swaps between targets at most four Manhattan grid steps apart. Run at most
six greedy passes.

The objective is the sum of squared geographic centre distances across affected
internal edges, plus a weighted sum across the international seam. Test seam
multipliers 1, 4, and 16. A swap represents an exchange of complete target
assignment groups, not a change to population values. This diagnostic operates
on their centres only. It does not include the original transport cost and does
not run Sinkhorn. No modified mapping was exported.

At multiplier 4:

| Fixed country → changed country | Median seam jump, before → after | Local internal 90th percentile, before → after |
| --- | ---: | ---: |
| Germany → Poland | 100 → 100 km | 78 → 78 km |
| Finland → Russia | 274 → 257 km | 493 → 493 km |
| Canada → United States | 677 → 448 km | 188 → 334 km |

The Canada–US seam improves by about 34%, but internal continuity becomes worse.
Increasing the penalty does not reliably improve the result. At multiplier 16,
Germany–Poland's median seam jump increases to 107 km and the local internal
maximum increases from 112 to 167 km.

This limited experiment does not rule out a better border-constrained fit. It
shows why a seam-only success metric would be unsafe.

## Recommended experiments

1. **Use a geographic adjacency mask.** Apply border constraints only to seams
   that represent real shared borders. Treat false contacts and missing seams
   as layout limitations, not as requests to pull unrelated population together.
2. **Penalize internal jumps as well as seam jumps.** Test a soft penalty across
   the target-cell neighbour graph. Retain the original transport objective and
   population constraints. Check source spread as well as centre distances, so
   the solver cannot hide a jump by mixing distant populations into one cell.
3. **Start with a coarse, coupled Germany–Poland fit.** This pair has a usable
   seam and moderate internal jumps. Alternate fixed-neighbour cost updates and
   Sinkhorn solves. A fixed neighbour permits a linear assignment penalty; an
   objective on the resulting means requires an outer update. Compare complete
   line footprints, internal and seam jumps, population retention, and runtime.
4. **Test Russia separately before adding more border anchors.** Its large
   internal jumps need a continuity constraint or a layout change. Check the
   historical coordinate preparation, including longitude wrap, but do not
   assume that this is the cause. More subdivision alone has not been tested.
5. **Allow explicit cuts where layout repair is out of scope.** H3-MON could mark
   a discontinuity along a drawn line. Do not draw an invented geographic bridge
   or add population to make the footprint appear connected. To restore missing
   country adjacencies, the cartogram geometry itself must change.

The first solver prototype should use KernelAbstractions and oneAPI, as the
current country fits do. New cost terms require valid GPU pruning bounds.
These audit and swap calculations use the CPU; they are not population solves.

## Local artifacts

The investigation files are in `output/border-audit/`, which is not tracked:

- `audit.cjs`, `experiment.cjs`, `plots.cjs`: local analysis scripts.
- `report.json`, `internal.json`, `seams.csv`: measurements.
- `traces.json`, `line-footprints.json`, `line-*.geojson`: selected lines.
- `experiments.json`: all one-way trial results.
- `seams.svg`: cartogram seam plot, blue for small jumps and red for large jumps.
- `lines.html`, `lines.png`: geographic footprint plots. Red segments connect
  target means; they are diagnostics, not mapped paths.

Run the scripts from the repository root with the installed H3-MON Node
dependencies. `experiment.cjs` also runs `audit.cjs`. `plots.cjs` uses headless
Chromium and closes it after the screenshot. It does not start H3-MON.
