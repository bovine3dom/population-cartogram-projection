# Selective border separation: experiment

## Aim

Allow some low-population borders to separate if this reduces distortion.
Do not replace the approved layout on the basis of an optimization score.
Keep every component's population tile budget exact. Keep lakes empty.
Do not add connecting lines or country-specific position rules.

## Research basis

Gastner, Perrault, and Feng discuss the conflict between shape preservation
and contiguity in [their 2021 conference abstract](https://doi.org/10.5194/ica-abs-3-87-2021).
Their example relaxes contiguity for small-value regions. It is a handmade
proof of concept, not an algorithm for population-weighted border segments.
Their thin connecting lines and fixed-size nodes are not used here.
The paper supports testing the trade-off, not these density thresholds.

## Population audit

`audit_border_population.py` measures each represented component-pair border.
It uses the existing H3-5 population sources, not country-average density.
Lake-aware land guides exclude administrative borders that lie wholly in
selected lakes. A border without measurable physical length is unknown;
it is not classified as empty or sparse.

The first audit uses a corridor about 25 km wide on each side of the border.
It records total population, corridor area, mean density, and a length-weighted
90th percentile of segment density. Segment spacing is about 25 km.

The strict limits are 10 people/km² for the mean and 25 people/km² for the
90th percentile. Both limits must pass. This admits 74 of 348 component pairs.
A wider test uses 20 and 50 people/km² and admits 98 pairs.
These are test settings, not established cartographic thresholds.

Examples from the strict audit:

| Border | Mean people/km² | 90th percentile | Eligible |
| --- | ---: | ---: | --- |
| Kazakhstan–Russia | 7.12 | 14.78 | Yes |
| Mongolia–Russia | 1.25 | 1.88 | Yes |
| China–Mongolia | 1.25 | 1.15 | Yes |
| China–Kazakhstan | 8.91 | 24.20 | Yes |
| China–Russia | 17.00 | 34.44 | No |
| China–North Korea | 136.17 | 250.92 | No |
| China–Vietnam | 102.48 | 188.79 | No |

China's eastern side is mostly coast. The test distinguishes this coast from
its northeast and southeast land contacts. It does not assume that all borders
on one side of a country have low population.

### Audit limits

Equal Earth preserves area, not distance. Corridor widths and border lengths
are projected approximations, particularly at high latitude. H3 cells place
population at their centres. Short borders and corridor edges have sampling
error. Segment area is estimated from its share of border length. A short,
dense settlement can escape the 90th-percentile test.

Eligibility currently applies to a whole component pair. It does not prove
that an opened part corresponds to a sparse source segment. A later test must
map individual populated border segments to the tile layout.

## Matched layout tests

`relax_sparse_borders.py` starts from the 55,000-tile local-lake layout.
It uses paired tile exchanges, a native-outline guide, a perimeter cost,
and a cost for new interior gaps. All components stay connected.
Existing non-eligible contacts stay protected. No new false contact is allowed.
Independent islands, lake cells, and immediate lake-shore labels stay fixed.

Interior gaps can occur only near an initially touching eligible border.
Their total cell count is capped. A nearest-component-distance limit prevents
large separation of formerly touching neighbours. This limit does not bound
every local gap width. Existing missing contacts are not rebuilt by force.

Each test has a matched control with `--preserve-all`. The same components,
costs, and move choices are used. Only permission to lose eligible contacts
changes. This separates the effect of border relaxation from extra refinement.

`review_sparse_borders.py` measures shape error independently of the search
objective. It scales the native dry-land outline to equal area and aligns its
centroid with the tile shape. Error is one minus intersection-over-union.
It does not fit a rotation. It also reports newly enclosed empty cells.
These new empty cells are not labelled as real lakes.

## First 100-round result

| Test | Lost existing contacts | Weighted shape error | New enclosed empty cells |
| --- | ---: | ---: | ---: |
| Input | 0 | 0.42690 | 0 |
| Strict control | 0 | 0.41934 | 23 |
| Strict relaxed | 1 | 0.41971 | 24 |
| Wider control | 0 | 0.40985 | 35 |
| Wider relaxed | 6 | 0.41016 | 37 |

Lower shape error is better. The wider tests use guide weight 16, gap cost 1,
and a six-cell nearest-gap setting. The strict tests use 4, 4, and three cells.
Do not compare their search energies directly.

Visual inspection of Eurasia shows similar improvements in the relaxed and
protected tests. The strict relaxed test breaks Sweden–Finland. This partly
undoes the previous mainland repair. The wider relaxed test also loses some
African and American contacts. Neither relaxed test beats its matched control
on the independent shape score. China changes little. Russia improves in
both controls without losing an existing contact.

These results do not yet show a benefit from selective separation. They do
not disprove the idea: small local moves and fixed guide centres can stop at
poor local solutions. Longer matched tests are the next check. After that,
test larger regional moves and source-segment population constraints rather
than simply increasing the number of optional borders.

## Reproduction

Use `output/auto-cartogram/geometry-env/bin/python`.
Each script has positional input paths and a `--help` command.

- Inputs: `output/auto-cartogram/world-55000-dissolved-input`.
- Population: `output/auto-cartogram/world-55000-h3-5-density/sources.csv`.
- Dry-land guides: `output/auto-cartogram/geography-lake-guides-final`.
- Starting layout: `output/auto-cartogram/geography-margin1-lake-vacancies-final`.
- Audits: `output/auto-cartogram/sparse-border-audit-25` and `sparse-border-audit-25-wide`.
- Trials: `output/auto-cartogram/sparse-border-{control,strict,wide,wide-control}-100`.

Reports record settings and input hashes. The published H3-MON map is unchanged.
