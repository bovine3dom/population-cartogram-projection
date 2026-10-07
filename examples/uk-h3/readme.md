# UK H3 workflow

Use this example to prepare UK population data, fit the OWID cartogram, and export
both Arrow files for H3-MON. The tested choice is **H3-7 with 5×5 subdivision**.
See [results and size estimates](results.md) before you start a larger run.

The core fits weights. These examples own country selection, H3, city labels,
file formats, and rendering. A new export does not require another fit.
The original `examples/uk_h3.jl` entry point remains available.

## 1. Prepare sources

Run from the repository root. This environment does not require CUDA.

```sh
julia --project=examples/uk-h3 -e 'using Pkg; Pkg.instantiate()'
mkdir -p output/uk-h3-res7
julia --project=examples/uk-h3 scripts/extract_kontur_country.jl \
  ~/projects/gtfs_ffs/data/kontur_h3.arrow 826 \
  output/uk-h3-res7/country-826-res7.arrow 7
```

The input is an external Kontur Arrow file with `h3` and `population` columns.
The command refuses to replace an existing file. Its final arguments are
`[RESOLUTION=8] [BOUNDARY.geojson]`.

Country membership is calculated at H3-8 with the supplied Natural Earth GeoJSON.
A cell is included if its centre is inside a UK polygon and outside its holes.
Overlapping polygons do not duplicate cells. For H3-7, the command then sums the
selected children's populations by H3 parent. It does not select the country
again at the parent resolution. The total population remains the same.
This is not an exact coastal population clip.

For an H3-8 trial, use a different output path and final argument `8`.
No script under `output/` is needed for data preparation.

## 2. Fit with oneAPI

The Intel HD Graphics P630 needs the legacy Level Zero driver on this machine.
This command uses KernelAbstractions through oneAPI. It has no CPU fallback.

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  julia --threads=8 --project=examples/uk-h3 -e '
    using oneAPI
    @assert oneAPI.functional()
    include("examples/uk_h3.jl")
    UKH3Example.main(ARGS; backend=oneAPI.oneAPIBackend())
  ' output/uk-h3-res7/country-826-res7.arrow output/uk-h3-res7/factor5 5
```

The final argument is the subdivision factor, not the H3 resolution.
Factor 5 replaces each OWID square with 25 squares. It retains the OWID outline;
the package does not calculate a new country outline.

The fit writes `mapping.csv`, `projected_population.csv`, and `summary.csv`.
The summary records the source resolution, backend, fit time, and retained
population share. Keep the source extract with these outputs.
Use a new output directory for each experiment: the fit can replace CSV files.

Each output square has approximately equal population. `population_density` is
the population-weighted mean source density in people/km². It uses `weight_mean`
and actual H3 cell areas, not the area of a cartogram square.
Sparse weights are not renormalized; some source population can be omitted.

For an optional SVG preview:

```sh
julia --project=examples/uk-h3 examples/render_h3_density.jl \
  output/uk-h3-res7/factor5/projected_population.csv \
  output/uk-h3-res7/factor5/density.svg
```

## 3. Prepare city names

Use an existing CSV with `name, country_code, latitude, longitude, population`,
or prepare a GeoNames snapshot. These commands require `curl` and `unzip`.
The download changes over time; retain its checksum and archive entry date.

```sh
curl -fL https://download.geonames.org/export/dump/cities15000.zip \
  -o output/uk-h3-res7/cities15000.zip
sha256sum output/uk-h3-res7/cities15000.zip
unzip -l output/uk-h3-res7/cities15000.zip
unzip -p output/uk-h3-res7/cities15000.zip cities15000.txt \
  > output/uk-h3-res7/cities15000.tsv
julia --project=examples/uk-h3 -e '
  using CSV, DataFrames
  cities = CSV.read(ARGS[1], DataFrame; delim=Char(9), header=false,
                    select=[2, 5, 6, 9, 15])
  rename!(cities, [:name, :latitude, :longitude, :country_code, :population])
  filter!(r -> r.country_code == "GB" && r.population > 50_000, cities)
  CSV.write(ARGS[2], cities)
' output/uk-h3-res7/cities15000.tsv output/uk-h3-res7/uk-cities.csv
```

## 4. Export both H3-MON files

This step reads the completed fit. It does not use the GPU or run the solver.
It refuses to replace existing export files.

```sh
julia --project=examples/uk-h3 examples/uk-h3/export_h3_mon.jl \
  output/uk-h3-res7/factor5/mapping.csv \
  output/uk-h3-res7/country-826-res7.arrow \
  output/uk-h3-res7/uk-cities.csv \
  output/uk-h3-res7/factor5/cartogram_weights_uk_h3_7_factor5_hilo.arrow
```

| File | Contents |
| --- | --- |
| `cartogram_weights_uk_h3_7_factor5_hilo.arrow` | Mapping weights, country code, city labels, and label prominence |
| `population_density_hilo.arrow` | Source H3 density in `value`, in people/km² |

Both files are uncompressed Arrow. Both use unsigned 32-bit `index_lower` and
`index_upper`. Reconstruct an index as `(UInt64(upper) << 32) | UInt64(lower)`.
The mapping retains source-normalized `weight` and target-normalized `weight_mean`.
H3-MON uses `weight_mean`. The density file uses source population before sparse
mapping losses. At H3-7, density is parent population divided by parent cell area;
it is not the mean of the children's densities.

The exporter selects `GB` cities with population greater than 50,000.
A label uses its city's H3 cell and the nearest contributed square to that cell's
weighted cartogram centre. Cities in one H3 cell share a combined label.
Unmatched cities go to `unmatched_cities.csv`; no nearby city is substituted.
`prominence` contains city population. Label rows can share a cartogram square,
so H3-MON can display fewer labels than the file contains.

Copy both Arrow files into `~/projects/H3-MON/www/data/uk-h3-7-factor5/`.
Set `data=uk-h3-7-factor5/population_density_hilo.arrow` and
`cartogram=uk-h3-7-factor5/cartogram_weights_uk_h3_7_factor5_hilo.arrow`.
Include Kontur, GeoNames, OWID, and Natural Earth in the `c` attribution parameter.
Credit [GeoNames](https://www.geonames.org/) under CC BY 4.0.

## Checks

These checks do not require a GPU or the external population and city files:

```sh
julia --threads=8 --project=examples/uk-h3 test/runtests.jl
julia --project=examples/uk-h3 test/uk_h3.jl
```

Sources: [OWID cartograms](https://owid.github.io/cartograms/),
[Kontur population](https://www.kontur.io/datasets/population-dataset/),
[GeoNames data](https://download.geonames.org/export/dump/),
[H3 polygon membership](https://h3geo.org/docs/api/regions/),
[oneAPI](https://juliagpu.github.io/oneAPI.jl/dev/).
