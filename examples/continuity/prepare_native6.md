# Native H3-6 population audit

Run `prepare_native6.jl` with the original Kontur H3-8 Arrow file, the coarse
planet input, and a new output directory. Optional country codes limit the run.
The script refuses to overwrite an output directory.

```sh
julia --project=examples/uk-h3 examples/continuity/prepare_native6.jl \
  POPULATION.arrow COARSE_INPUT.arrow OUTPUT [COUNTRY_CODES...]
```

The coarse input supplies the country list, not the new population values.
The script selects native H3-8 cell centres within Natural Earth map-unit
polygons, then aggregates their population to H3-6. Thus it can include areas
outside the old H3-5 source footprint. It does not rescale population to the
old country totals.

Each input cell has one country owner. If country polygons overlap, the lowest
numeric country code wins. Each output H3-6 cell also needs one owner. If it has
children in more than one country, the country with the most population wins.
A tie uses the lowest country code. The cell keeps all selected population.
`audit.csv` records overlap counts and population assigned across these borders.

`countries.csv` lists output counts and population. `missing-countries.csv`
lists requested countries with no selected output cells. Review both files
before fitting. `complete.txt` means that extraction finished, not that the
input or a planet map has passed publication checks.

The raw-cell index uses memory proportional to the population input. This is
a server-side preparation tool, not code for the mobile browser.
