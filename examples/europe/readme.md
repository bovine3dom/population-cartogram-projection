# Europe Example

This example carries the old country-by-country Europe fitting and output shape
onto the reduced `distribute` API. It fits 42 explicitly ordered countries
independently, uses France's Natural Earth source-code remap `250 -> 249`, and
defaults to the native factor-1 cartogram.

The first run prepares a reusable resolution-6 H3 source cache from the external
Kontur and Natural Earth Arrow inputs using `clickhouse local`. Run from the
repository root:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/europe/europe.jl
```

Source preparation requires the first two ignored inputs; every output run uses
the city input:

```text
make-lookup-table/population-data/kontur_population_20231101.arrow
make-lookup-table/population-data/country-boundaries/ne_10m_admin_0_map_units.arrow
make-lookup-table/population-data/tiny-cities.csv
```

See the population-data readmes, including `cities_wrangler.md`, for provenance
and preparation. The inputs used for the recorded run have SHA-256 checksums:

```text
c752f5b48a698867f911243be59b3a606b9f8054ac83b82d567a6b7b7776c869  kontur_population_20231101.arrow
2304331fe51ed73fedd3190ea89d83d176c12f6f77bf4770b6edf387172acb67  ne_10m_admin_0_map_units.arrow
9b586b8c6cd7db54756d903d0b2dd56af54471ebccf4ff907b4f89ecdd3a1484  tiny-cities.csv
```

Source preparation was verified with ClickHouse Local 25.1.4.53. Different
input or tool versions may change country assignment at boundary ties.
The documented command requires a functional NVIDIA CUDA GPU. The reference
output used CUDA.jl 6.1.0 on a GeForce GTX 1080 Ti with driver 570.211.01;
floating-point output may differ on other CUDA environments.

Optional arguments are:

```text
europe.jl [SUBDIVISION_FACTOR] [OUTPUT.arrow] [SOURCE_CACHE.arrow]
```

The default output is:

```text
output/europe/cartogram_weights_europe_factor1_hilo.arrow
```

The reusable source cache is `output/europe/sources-res6.arrow`. Remove that file
before running the command to regenerate it after changing either source input or
the preparation code. Source preparation reports unmatched and ambiguous boundary
coverage. The recorded inputs have 63,326 unmatched resolution-8 rows containing
6,582,390 people; those rows are excluded, matching the old exact-H3 join.
Each retained resolution-6 parent is assigned as a whole to its modal child
country code, including parents that cross a border.

The output's column order and nullable concrete types match the legacy hilo artifact:

```text
x, y, weight, population, code, label, weight_mean, index_lower, index_upper
```

`index_lower` and `index_upper` are the low and high `UInt32` halves of the
source's `UInt64` H3 index. The original index is reconstructed as:

```julia
(UInt64(index_upper) << 32) | UInt64(index_lower)
```

The old Europe artifact used factor 6. Factor 1 intentionally has fewer target
cells and different fitted weights; it is the initial bounded workflow requested
for this migration. Target count and dense transport memory grow with the square
of the subdivision factor.

With the recorded inputs, the source cache has 175,921 rows, population
587,812,741, and SHA-256
`46756f422caf6ec015399e8974df265c7015ddc8e039f594fed46315924fccd1`.
The factor-1 output has 344,904 rows, 42 countries, 1,509 labels, is about
20 MiB, and has SHA-256
`1f911f6c8b9bc3c48c1a83f23072202a2a8b0a9cabbab022d2d3a5a2afd0b272`.
