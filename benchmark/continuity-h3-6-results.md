# Native H3-6 planet results

Work window: 2026-10-14 22:51 UTC to 2026-10-15 04:51 UTC.
The four H3-6 datasets are additional maps. H3-5 and the existing regional
files are unchanged. H3-MON code, its default dataset, its service, and its
production zstd policy are unchanged. No viewport geometry option is used.

## Published choices

Use factor 2 as the first H3-6 comparison. Factor 1 has the smallest file.
Factor 3 gives more target detail. Factor 5 is a larger research option.
None meets a 100 MB browser-memory limit. Even the smallest pair of files
is slightly above 100 MB before HTTP compression.

All four contain 1,992,902 native H3-6 sources, 206 countries, and population
7,947,202,049. This is 68,417 below the old input; no rescaling hides the
difference. One owner is selected for each shared native cell. This moves
14,958,488 people between country totals but preserves the selected total.
A factor multiplies each target axis; factor 5 gives 25 times as many targets
as factor 1. MB and GB below use decimal units.

| Factor | Physical targets | Both files, MB | zstd-3 sample, MB | Stored rows per source | 99.5% ratio | Low-population 99.5% ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 54,931 | 103.48 | 55.01 | 2.521 | 2.000 | 1.970 |
| 2 | 219,724 | 115.99 | 63.63 | 2.843 | 2.284 | 2.036 |
| 3 | 494,379 | 151.96 | 84.20 | 3.828 | 3.029 | 2.273 |
| 5 | 1,373,275 | 244.24 | 133.16 | 6.386 | 5.197 | 2.588 |

The 99.5% ratio counts the largest contributions needed to retain 99.5% of
each source's mass, then averages over sources. It is not the stored row count.
The sharp H3-5 reference has a ratio of 2.026 and 2.851 stored rows per source.
The source resolutions and populations differ, so this is not a paired test.

Low-population sources can fit into one actual target by population alone.
Their ratio helps separate broad transport from the need to split a large
population among small targets. The population-capacity lower bounds for the
full source set are 1.004, 1.044, 1.141, and 1.522. These are only lower bounds;
flow and moment constraints also require contributions.

The zstd numbers use a local level-3 sample. They are not measured production
responses, and they do not imply a recommended nginx setting. The Arrow files
use lossless dictionary packing, not gzip or internal IPC compression.

## Browser cost

The actual published files pass headless Chromium checks with their JSON
metadata. Each check loads all geographic cells. Three camera changes include
the world view, the antimeridian, and return to the initial view. Source
coverage remains unchanged and the tests report no errors. The existing
legend transform warning remains. File and application hashes bind each test
to its inputs.

| Factor | Retained backing storage, GB | Retained JS heap, MB | Displayed labels |
| --- | ---: | ---: | ---: |
| 1 | 1.304 | 101.7 | 1,712 |
| 2 | 1.344 | 129.9 | 1,715 |
| 3 | 1.404 | 176.7 | 1,715 |
| 5 | 1.561 | 347.4 | 1,715 |

These are CDP measurements after garbage collection, not total process peaks
or phone benchmarks. All files retain 1,715 labelled sources. Factor 1 has
fewer displayed labels because target positions collide. File reduction does
not remove the large native geographic-layer memory cost. Keep H3-5 available.

## Model and approximation

The source fit uses KernelAbstractions and oneAPI. It adjusts coarse flows to
native population and splits each coarse source into its native children.
All 206 source fits use optimized stages; none uses proportional inheritance.
Target subdivision then uses CPU linear programming. It preserves each coarse
flow and constrains fine target mass, raw geographic XYZ means, and density.
This is not a new whole-planet fine-grid border optimization. Existing border
and orientation defects remain. Do not call the result fold-free.

Factors 1, 2, and 3 also use approximate moment packing. Their measured maximum
target total variations are 0.00923, 0.08998, and 0.07550. The source mean can
move by at most 0.02, 0.1, and 0.1 coarse coordinate units per axis before
serialization. A coarse cell has width 2. These are mean-position bounds,
not bounds on each source distribution's total variation.

Actual binary comparisons preserve city and navigation anchors. Target mass,
geographic means, and complete density pass their limits. Other queries can
change. The tested half-missing query loses 0, 15, and 26 previously covered
targets for factors 1, 2, and 3. Renormalization after missing-data filtering
can increase errors. See each published `query-errors.csv`.

Factor 5 does not use additional moment packing. Its tested packed version
passes checks but saves only 3.20 MB, or 1.3%, while allowing target variation
up to 0.07352 and losing seven targets in the half-missing query. The small
saving does not justify that extra approximation. The diagnostic is retained.

The final factor-2 subdivision has no uniform cell fallback. Factors 3 and 5
each retain four small numerical fallback cells. Large Australian and US
failures were repaired before factor-5 assembly. Failed packing blocks retain
their original contributions; these are separate from subdivision fallbacks.

Native source population uses Float32 only after an exact round-trip check.
Every selected population value is exactly representable; no population was
rounded. Density uses Float32 with relative error below `6e-8`. Use Apache
Arrow JavaScript or another reader that supports replacement dictionaries.
With Arrow.jl 2.8.1, use `Arrow.Stream`, not `Arrow.Table`.

## Paths and links

Published root: `/home/olie/projects/H3-MON/www/data/`.
Use these paths on the existing H3-MON host:

- `/?data=planet-h3-6-factor1-continuity-native/population_density_hilo.arrow`
- `/?data=planet-h3-6-factor2-continuity-native/population_density_hilo.arrow`
- `/?data=planet-h3-6-factor3-continuity-native/population_density_hilo.arrow`
- `/?data=planet-h3-6-factor5-continuity-native/population_density_hilo.arrow`

Each folder has `population_density_hilo.json`, `cartogram_weights_hilo.arrow`,
`population_density_hilo.arrow`, audit reports, geometry reports, and hashes.
The JSON selects the corresponding cartogram with `trimFactor: 0` and
`cartogramLineProbe: true`. A full factor-2 reference is also published under
`planet-h3-6-factor2-continuity-native-full`; its files total 141.18 MB.

## Checks and reproduction

The final checks pass:

- 21 sparse-solver tests on each of CPU and oneAPI.
- 16 hierarchy tests on each backend and four local-transfer tests.
- 19 subdivision tests and 23 moment-packing tests.
- 15 native binary tests, ten geometry tests, and four navigation tests.
- Two Python stream tests and three publisher tests.

Full-data checks compare every Arrow column, native source coverage, country
mass, city names, density, packing queries, and published hash manifests.

See [the work log](continuity-h3-6-work-log.md),
[native fitting](../examples/continuity/native_hierarchy.md),
[target subdivision](../examples/continuity/target_subdivision.md), and
[publication checks](../examples/continuity/native_publication.md).
Exact logs, scripts, rejected trials, and browser reports remain under
`output/continuity-h3-6-six-hours/`. Complete fitted country checkpoints remain
under the separate `output/planet-h3-6-native-*` roots. Do not use a partial
checkpoint as a published fit.
