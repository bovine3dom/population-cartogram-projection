# France IRIS Example

This example maps metropolitan France's small INSEE IRIS statistical units to
the OWID France cartogram. The population fit uses authoritative IRIS codes,
populations, and WGS84 centroids. GeoNames is used separately for human-readable
city labels such as Paris and Nice; it does not participate in the transport
solve. The fitted fractional mapping preserves each IRIS code directly.

The source files came from:

- [IGN CONTOURS-IRIS](https://cartes.gouv.fr/rechercher-une-donnee/dataset/IGNF_CONTOURS-IRIS), release `CONTOURS-IRIS_3-0__GPKG_LAMB93_FXX_2024-01-01`
- [INSEE 2022 housing and population data](https://www.insee.fr/fr/statistiques/8647012#consulter)

`scratch.sql` joins those files by exact IRIS code and transforms Lambert-93
(`EPSG:2154`) centroids to WGS84. Keep the statistical and geometry vintages
explicit: this pair has 48,568 exact code matches and one metropolitan code
mismatch (`140110000` versus `145810000`).

It also calculates ellipsoidal IRIS area with `ST_Area_Spheroid` and source
population density as `P22_PMEN / area_km2`. This example derives the
population-weighted density from the package's transport weights; it is not
averaged equally across IRIS rows.

## Input Cleaning

`iris-population.csv` has 49,276 unique nine-character IDs. Read `index` as a
string because IDs can start with zero or contain Corsican `2A`/`2B` prefixes.
The supported metropolitan fit contains 48,416 finite, positive-population rows.
The example reports rather than silently imputes these exclusions:

- 708 rows lack centroids: 707 are from Guadeloupe, Martinique, French Guiana,
  or Reunion, and one is the release mismatch above.
- 169 rows have zero population; 17 also lack centroids.

Adding overseas points to the current source-extrema transform would distort all
metropolitan costs. Full-France support therefore needs matching overseas
geometries and an explicit disconnected-geography policy, not a nearest-place
fallback.

## Run

The example uses CUDA directly. Native resolution is the default:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/france/iris_population.jl
```

Pass a subdivision factor as the first argument. Factor 3 is close to ten IRIS
rows per cartogram cell:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/france/iris_population.jl 3
```

| Factor | Cells | IRIS rows/cell | Host + accelerator dense baseline |
|---:|---:|---:|---:|
| 1 | 438 | 110.54 | 0.32 GiB |
| 3 | 3,942 | 12.28 | 2.84 GiB |
| 6 | 15,768 | 3.07 | 11.38 GiB |

The solver stores the cost and its transpose on both host and accelerator, so
subdivision is an explicit quality/performance choice. Subdivision and country
filtering are example-owned:

```julia
cartogram = load_cartogram(250; factor=3)
mapping = distribute(
    select(cartogram, :x, :y), sources;
    backend=CUDA.CUDABackend(),
)
```

The estimates exclude temporary allocations and runtime overhead.

The output `mapping.csv` remains the authoritative `x, y, id, weight,
weight_mean` mapping.
`dominant_iris.csv` is a convenience regional lookup: each cell
gets the IRIS code contributing the most transported population, not simply the
nearest centroid. Projections and population accounting should continue to use
the fractional mapping.
`projected_population_density.csv` contains the factor-specific density grid and
the nullable city-label column used by the renderer.

## City Labels

The legacy workflow's city labels were not part of the initial package
migration. The data-association and placement stages are restored here as an
optional post-fit step:

1. `scratch.sql` filters the GeoNames `tiny-cities.csv` extract to French cities
   over 300,000 people.
2. It assigns each city to an IRIS code with a point-in-polygon join against the
   authoritative IRIS boundaries. Nearest-centroid matching is not used.
3. The local `place_city_labels` helper follows that IRIS source's fractional mapping, computes
   its `weight`-weighted cartogram centre, and places the name on the
   nearest contributed cartogram cell.

The seven-row `iris-cities.csv` fixture includes Paris, Marseille, Lyon,
Toulouse, Nice, Nantes, and Marne La Vallée. `city_labels.csv` contains the full
cartogram grid plus a nullable `label` column; `city_label_placements.csv` keeps
the source IRIS and GeoNames coordinates for auditing.

The generic Luxor renderer remains in `make-lookup-table/lib.jl`; migrating it
is still separate from the fitting and annotation APIs.

This example includes a standalone renderer for the projected density CSV:

```sh
julia +1.12.1 --project=make-lookup-table \
  examples/france/render_density.jl \
  output/france-iris-factor3/projected_population_density.csv \
  output/france-iris-factor3
```

It writes three labeled views so the color-scale tradeoff is explicit:

- `france_population_density_quantile.png` preserves detail across the full
  density distribution.
- `france_population_density_log.png` uses actual density on a log scale clipped
  to the 1st–99th percentile.
- `france_population_density_linear_p99.png` emphasizes the largest urban
  concentrations on a linear scale clipped at the 99th percentile.

The local source was GeoNames `cities500.zip`, whose archived `cities500.txt`
entry is dated 2026-04-14. Its SHA-256 is
`754948177b169cb2ddd24dc90c56465e9be3324cab970d3901f25aebcc8aa548`.
GeoNames data is licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); attribution:
[GeoNames](https://www.geonames.org/).
