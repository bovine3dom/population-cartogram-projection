# Island capacity audit

This example starts the [automatic cartogram plan](../../auto-cartogram.md).
It identifies geographic polygon components, sums their Kontur populations,
and compares reviewed matches with the fixed OWID tile layout.

It does not generate a new layout or run population transport. It does not
change production data or the core solver. All processing is headless and uses
CPU code. No GPU or plotting package is required.

## Run

Run from the repository root:

```sh
julia --project=examples/auto-cartogram -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/auto-cartogram test/auto_cartogram.jl
julia --project=examples/auto-cartogram examples/auto-cartogram/audit.jl \
  ~/projects/gtfs_ffs/data/kontur_h3.arrow \
  make-lookup-table/population-data/country-boundaries/ne_10m_admin_0_map_units.geojson \
  data/cartogram.csv output/auto-cartogram/indonesia-unmatched
```

The population file is external. It must have `h3` and `population` columns.
Selected rows must have unique H3-8 IDs and finite positive population values.
The boundary file uses Natural Earth's `ISO_N3_EH` country property.
The target file is headerless `x,y,country`, on the current step-2 square grid.

The optional final arguments are `[COUNTRY=360] [MATCHES.csv]`. Use a new output
directory for each run. Existing paths are refused. Results are published only
after all calculations and file writes succeed.

## Review matches

First inspect `overview.svg`, `components.csv`, and `targets.csv`. Do not infer
island names from component size alone. The SVG shows longitude and latitude
above the artwork. Neighboring countries provide context in the artwork panel.
Ring points are sampled for this preview only; population selection uses the
full input geometry.

A match table has this header:

```text
label,longitude,latitude,target_x,target_y,status,evidence
```

The geographic seed must lie well inside the intended polygon. Its containing
H3-8 cell selects the source component. The target seed must be an existing
square in the intended side-connected artwork component. Each source and target
component can appear only once. Add the reason for each match to `evidence`.

Use `reviewed` only after checking shape, position, and available border context.
Use `provisional` for uncertain matches. Only reviewed matches enter the capacity
bound. Unreviewed sources and targets are pooled into `unmatched-remainder`.
This pool is an accounting device, not a proposed transport group.

The bound is conditional on those matches. A visually identified artwork shape
can include more than one real island. This first version does not support such
many-to-one matches. Keep them provisional until that ambiguity is resolved.

## Method and limits

- Treat each input Polygon as a candidate geographic component. Preserve holes.
  MultiPolygon parts retain separate identities. Reuse the existing H3 polygon
  fill from `scripts/extract_kontur_country.jl`.
- Select population by H3 cell centres before any aggregation. Do not split H3
  cells at coasts. Export native IDs with their component memberships.
- Reject duplicate polygons, overlapping H3 ownership, invalid basic coordinate
  structure, and antimeridian-spanning polygons. This is not a general geometry
  repair tool. It does not merge connected polygon parts or identify physical
  landmasses across countries. Indonesia is the first test case.
- Derive component IDs from the country code and a polygon-coordinate hash.
  Feature and polygon order do not affect IDs. Geometry edits and ring changes
  do affect IDs. Input hashes identify the exact boundary snapshot.
- Flag source population in cells with a neighbour outside their component.
  This includes coasts and international land borders. It is a review quantity,
  not an estimate of population error.
- Compute largest-remainder tile budgets at the existing country tile count.
  Use component IDs to break ties. Do not enforce a minimum tile count. Report
  inhabited components that receive zero tiles; their population is not removed.
- Do not infer the population year from the file name or the national total.
  The supplied local Arrow file has no declared year. Use raw Kontur sums; do
  not rescale them to OWID totals.

For population `P_i`, tiles `T_i`, and country totals `P` and `T`:

```text
capacity_i = P * T_i / T
excess_i = capacity_i - P_i
coarse_cross_component_lower_bound = 0.5 * sum(abs(excess_i))
```

Include the unmatched remainder on both sides. Pooling can reduce the bound,
but does not increase it when matches are valid. With no reviewed matches, the
reported bound is null, not evidence that the layout has no island problem.
This is a capacity calculation, not a measurement of an existing transport plan.

## Outputs

| File | Content |
| --- | --- |
| `components.csv` | Polygon IDs, population, source counts, bounds, tile budgets, review status |
| `targets.csv` | Deterministic artwork component IDs, tile counts, seeds, review status |
| `capacity.csv` | Reviewed groups and remainder, shares, capacities, signed excess population |
| `source-components.arrow` | Native `id,value,country_code,component_id` for later component solves |
| `overview.svg` | Geographic and artwork preview for match review |
| `manifest.json` | Input and code hashes, environment identity, totals, warnings, elapsed time |

`boundary_cells` counts all H3-8 centres in a polygon. `source_cells` counts
those with population rows. A polygon without rows is not proof that the island
is uninhabited. An island absent from the boundary file cannot appear in either
count. Check coverage before using these outputs to generate a map.

## Sources

- [H3 region functions](https://h3geo.org/docs/api/regions/): centre-based polygon membership.
- [H3.jl](https://github.com/wookay/H3.jl): Julia bindings for H3.
- [Natural Earth map units](https://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-admin-0-details/).
- [Kontur population](https://data.humdata.org/dataset/kontur-population-dataset).
- [OWID cartograms](https://owid.github.io/cartograms/).
