# Germany at H3-7

This example uses the UK workflow with country code `276` and city code `DE`.
It keeps the OWID outline and uses 5×5 subdivision. It uses KernelAbstractions
through oneAPI, with no CPU fallback. The core package is unchanged.

Run these commands from the repository root. Use the environment and GeoNames
archive from the [UK workflow](../uk-h3/readme.md).

```sh
mkdir -p output/germany-h3-res7
julia --project=examples/uk-h3 scripts/extract_kontur_country.jl \
  ~/projects/gtfs_ffs/data/kontur_h3.arrow 276 \
  output/germany-h3-res7/country-276-res7.arrow 7
unzip -p output/uk-h3-res7/cities15000.zip cities15000.txt \
  > output/germany-h3-res7/cities15000.tsv
julia --project=examples/uk-h3 -e '
  using CSV, DataFrames
  cities = CSV.read(ARGS[1], DataFrame; delim=Char(9), header=false,
                    select=[2, 5, 6, 9, 15])
  rename!(cities, [:name, :latitude, :longitude, :country_code, :population])
  filter!(r -> r.country_code == "DE" && r.population > 50_000, cities)
  CSV.write(ARGS[2], cities)
' output/germany-h3-res7/cities15000.tsv output/germany-h3-res7/germany-cities.csv
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  julia --threads=8 --project=examples/uk-h3 examples/germany-h3/run.jl \
  output/germany-h3-res7/country-276-res7.arrow \
  output/germany-h3-res7/germany-cities.csv output/germany-h3-res7/factor5
```

The source extract has 74,772 H3-7 cells and a population of 83,249,503.
It sums the selected H3-8 children. It uses the same boundary selection as the
UK workflow, not an exact coastal population clip.

The run refuses to replace an existing output directory. It writes the mapping,
projected population, and summary CSV files. It then writes both H3-MON files:

- `cartogram_weights_germany_h3_7_factor5_hilo.arrow`
- `population_density_hilo.arrow`

Both files use unsigned 32-bit index halves. City labels use GeoNames cities with
population greater than 50,000. See `unmatched_cities.csv` for omitted labels.
The summary records the fit time, backend, and retained population share.
