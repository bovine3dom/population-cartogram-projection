# Selective border separation: experiment

**Follow-up:** [Large regional moves](regional_release.md) test much larger
separations. The negative results below apply to the earlier local tests.
They do not establish that large regional moves cannot help.

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

## Longer runs and deliberate opening trials

Both wider runs completed 400 rounds. The protected control scores 0.39997;
the relaxed run scores 0.40038 and loses seven existing contacts. More rounds
do not reverse the result. Their newly enclosed empty-cell counts are 38 and
39. Neither candidate is approved.

Added an optional opening phase in `seed_sparse_borders.py`. It ranks eligible
contacts by their current guide cost. It moves boundary tiles to other empty
positions while retaining component counts, connectivity, other existing true
contacts, and the gap limits. A complete opening can temporarily increase the
search objective by at most 500 units. Failed openings are rolled back.
Ordinary downhill refinement follows. An opened border may close again.

This tests whether a short-term energy barrier prevents useful separation.
It does not assume that a forced opening is an improvement. An optional
500-tile minimum restricts the opening moves to larger components. The density
rule still applies globally; there are no named-country overrides.

| Additional 100-round test | Shape error | New enclosed empty cells |
| --- | ---: | ---: |
| Three openings, no size minimum | 0.40999 | 37 |
| Three openings, 500-tile minimum | 0.40989 | 100 |
| Small-gap protected control | 0.41228 | 24 |
| Small-gap opening trial | 0.41246 | 28 |

The large-component trial opens China–Russia. Russia's error is 0.38727,
compared with 0.39105 in the matched wider control. China's error is slightly
worse. The small Russia gain does not justify 100 newly enclosed empty cells.

The small-gap pair uses gap cost 16, a two-cell nearest-gap setting, and a
64-cell interior-gap budget. The opening trial temporarily separates
Kazakhstan–Russia, but refinement restores that contact. Russia's error is
0.41919 versus 0.42379 in its matched control. China is unchanged between the
two runs. The world score remains slightly worse in the opening trial.

Visual checks covered Eurasia in both 400-round runs and both opening variants,
the small-gap pair, Europe, and a world view. Longer runs can worsen regional
relationships even while native-outline overlap improves. Thus this overlap
score cannot be the sole acceptance test.

The independent geography audit also finds one extra source-landmass part in
the 400-round protected control. The UAE separates when an existing false
contact is removed; its true contacts were already missing in the input.
Protecting existing true contacts is not the same as preserving every current
landmass connection. The wider relaxed run adds four parts across two source
landmasses. This is another reason not to replace the current layout.

A 50 km corridor sensitivity check admits 67 pairs under the strict limits.
Kazakhstan–Russia and Mongolia–Russia still pass. China–Kazakhstan no longer
passes. Border classification must retain its scale and uncertainty.

Next, combine source-segment population measurements with joint regional
moves and relative-position checks. Review inherited coast constraints too:
protecting every old concavity can preserve an already distorted coastline.
Do not infer that all of China's eastern distortion comes from land borders.

## Reproduction

Use `output/auto-cartogram/geometry-env/bin/python`.
Each script has positional input paths and a `--help` command.

- Inputs: `output/auto-cartogram/world-55000-dissolved-input`.
- Population: `output/auto-cartogram/world-55000-h3-5-density/sources.csv`.
- Dry-land guides: `output/auto-cartogram/geography-lake-guides-final`.
- Starting layout: `output/auto-cartogram/geography-margin1-lake-vacancies-final`.
- Audits: `output/auto-cartogram/sparse-border-audit-25` and `sparse-border-audit-25-wide`.
- Trials: `output/auto-cartogram/sparse-border-{control,strict,wide,wide-control}-100`.

For opening trials, add `--seed-borders 3`, optionally with
`--seed-minimum-tiles 500`. The default has no opening phase.
All 182 automatic-cartogram tests pass. Reports record settings and input
hashes. The published H3-MON map is unchanged.
