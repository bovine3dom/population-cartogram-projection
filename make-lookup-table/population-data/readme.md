The external `kontur_population_20231101.arrow` was derived from the Kontur
Population dataset published through
https://data.humdata.org/dataset/kontur-population-dataset. It contains
resolution-8 H3 indexes and population values. The repository does not
redistribute this roughly 503 MiB file.

Country assignment uses the external Natural Earth H3 table under
`country-boundaries/`. From the repository root, create a small canonical
country extract with:

```sh
julia scripts/extract_country_h3.jl COUNTRY_CODE PARENT_H3_RESOLUTION
```

The script requires `clickhouse local`, reproduces the scratch workflow's exact
H3 join, sums population by parent, assigns each parent to its modal country,
and writes `country-CODE-resN.arrow`. Parent resolution must be between 0 and
the inputs' resolution of 8. The script validates the small result before moving
it into place. Generated Arrow files are ignored.

For the bounded UK migration check:

```sh
julia scripts/extract_country_h3.jl 826 6
```

This produces 8,346 `UInt64` H3 sources with total population 66,956,569 and
SHA-256 `cec7d16d8d05e3fe4848e363e35fd72477a03a6adf61595f1875b9570330bd06`.
