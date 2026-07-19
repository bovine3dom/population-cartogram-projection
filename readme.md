# Population Cartogram Projection

Experimental Julia code for mapping population-weighted geographic centres onto
the [Our World in Data population cartogram](https://owid.github.io/cartograms/).

The first supported path accepts one country's source table with these columns:

```text
id, population, x, y, country_code
```

`id` is opaque and can be an H3 index, NUTS code, ONS code, IRIS code, or another
stable identifier. `x` and `y` are WGS84 longitude and latitude in degrees. The
cartogram's downward-pointing vertical axis is handled internally.

The fixed-eta API returns a dense fractional mapping:

```text
id, country_code, cell_id, source_share
```

`source_share` is the fraction of a source row's population assigned to an OWID
cell and sums to approximately one for each source.

## Quick Start

Instantiate the root project and run the complete CPU example:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --threads=auto --project=. examples/regional_centres.jl
```

The example validates the five-source fixture, fits a sparse mapping, projects
an extensive household count and a population-weighted employment rate, and
writes these files under `output/regional-centres/`:

```text
mapping.csv
source_retention.csv
projected_households.csv
projected_employment_rate.csv
summary.csv
```

The same workflow can be used programmatically:

```julia
using CSV, DataFrames, PopulationCartogramProjection

sources = CSV.read("test/fixtures/synthetic_sources.csv", DataFrame)
sources.households = [510_000, 760_000, 1_080_000, 390_000, 310_000]
sources.employment_rate = [0.71, 0.74, 0.69, 0.76, 0.67]

grid = load_owid_grid()
fitted = fit_mapping_auto(sources, grid; backend=:cpu)
households = project_extensive(
    fitted.mapping, sources, grid; value=:households,
)
employment_rate = project_intensive(
    fitted.mapping, sources, grid; value=:employment_rate,
)
```

Existing tables do not need to be renamed in place. Adapt column names and a
constant country code while preserving unrelated value columns:

```julia
sources = canonicalize_sources(
    raw;
    id=:index,
    population=:population,
    x=:longitude,
    y=:latitude,
    country_code=250,
)
```

`canonicalize_sources` validates but does not silently drop or aggregate rows.
Filter or repair missing coordinates and non-positive populations explicitly
before calling it.

`fit_mapping`, `fit_mapping_auto`, and `solve_sinkhorn` require an explicit
`backend`; they never select or fall back to another device silently. Run the
test suite with:

```sh
julia --threads=auto --project=. -e 'using Pkg; Pkg.test()'
```

Numerical tests run for every functional backend available on the machine.

## Project Values

The mapping joins to source values by `(country_code, id)`. For each mapping row,

```text
transport_mass = population * source_share
```

`project_extensive` distributes a source-level count or total as
`value * source_share` and sums it by target cell. `project_intensive` calculates
a population-weighted mean as
`sum(value * transport_mass) / sum(transport_mass)`. Its cell output includes
`projected_population`, the denominator used for that mean.

Both helpers return `cells`, `source_retention`, and `metadata`. They preserve
the supplied mapping weights: sparse shares are not renormalized. Retained and
dropped share are reported per source, while metadata reports projected and
dropped extensive totals or projected and dropped population. All relevant grid
cells are retained in grid order. A cell with no retained contribution receives
zero for an extensive value and `missing` for an intensive value.

For a one-identifier-per-cell regional lookup, derive the source contributing
the most transported population:

```julia
assignment = dominant_source_assignment(fitted.mapping, sources, grid)
```

This compares `population * source_share`, not raw shares or nearest-centre
distance. The fractional mapping remains authoritative for projection and
population accounting.

## Target Subdivision

The native grid can be filtered and uniformly subdivided before fitting:

```julia
native_grid = load_owid_grid(; country_code=250)
grid = subdivide_grid(native_grid; factor=3)

# Or choose the uniform square factor nearest a desired cell count.
grid = subdivide_grid(native_grid; target_cells=cld(nrow(sources), 10))
```

Every parent receives `factor^2` children. Child IDs are deterministic and the
grid includes `parent_cell_id`, which projection outputs preserve. Uniform
target mass therefore gives every parent the same aggregate mass as at native
resolution. Subdivision is explicit because dense cost size grows by
`factor^2`; it does not add geographic information to source centre points.

The real [`examples/france`](examples/france/readme.md) workflow exercises IRIS
codes, non-canonical input columns, subdivision, and dominant assignment. It
uses exact IRIS identifiers for fitting; GeoNames remains an optional source of
human-readable city labels.

## Optional City Labels

City labels are a post-fit annotation, separate from population matching. First
associate each city with a source ID using the source geography: for example,
point-in-polygon against IRIS boundaries or H3 indexing for an H3 source table.
Then place each label on the weighted centre of that source's fitted cartogram
footprint:

```julia
# labels contains id, country_code, and name.
labeled = place_source_labels(fitted.mapping, labels, grid; label=:name)
cartogram_with_labels = labeled.cells
city_placements = labeled.placements
```

`place_source_labels` chooses the contributed target cell nearest each source's
`source_share`-weighted centre. It preserves all target cells and joins multiple
names that land on one cell; missing and blank labels are ignored. GeoNames is
therefore useful for display names and coordinates, but it is not used to create
or reconcile the population-source table or alter the transport solve.

## Spatial Scaling

Each fit independently maps source longitude extrema to the target `grid_x`
bounds and negated-latitude extrema to the target `grid_y` bounds. A coincident
source axis, including a one-source country, maps to the target midpoint.
Distances are measured in target-grid steps, stored as `Float32`, divided by the
per-run maximum distance, and raised to `cost_power`.

This preserves the established package behavior and bounded UK comparison. It
also means a changed source geography or outlier can change every spatial cost,
which is accepted because each source and target release produces a new mapping.
`fit_mapping_auto` records the actual source bounds, target bounds, grid step,
distance scale, and `cost_power` in `metadata.spatial_transform` for auditing.
The transform is not intended for reuse across releases.

A centre point remains only an approximation of a region. It does not preserve
the region's boundary, shape, adjacency, or internal population distribution.
Use population-weighted centres where available. Antimeridian-spanning,
disconnected, island, and overseas geographies still require an explicit policy
or multiple support points.

## Backend Selection

Select the backend on every fitting or solver call:

```julia
cuda_mapping = fit_mapping(sources; backend=:cuda)
amd_mapping = fit_mapping(sources; backend=:amdgpu)
metal_mapping = fit_mapping(sources; backend=:metal) # after `using Metal`
intel_mapping = fit_mapping(sources; backend=:oneapi)
cpu_mapping = fit_mapping(sources; backend=:cpu)
```

All backends run the same KernelAbstractions row, column, and marginal kernels.
There is no separately maintained CPU or direct-CUDA solver. The CPU backend
requires no system setup and is intended for modest regional problems. Its
256-workitem reductions are GPU-oriented and allocate more than a dedicated CPU
algorithm would, so it is not intended to replace GPU execution for large H3
workloads.

The `:cuda` backend requires an NVIDIA CUDA-capable GPU and functional CUDA
driver. Check availability with:

```sh
julia --project=. -e 'using CUDA; println(CUDA.functional())'
```

The `:amdgpu` backend requires a supported AMD GPU and functional ROCm/HIP
installation. AMDGPU.jl currently documents ROCm 6.0 or newer. Check both the
software stack and device detection with:

```sh
julia --project=. -e 'using AMDGPU; AMDGPU.versioninfo(); println((AMDGPU.functional(), AMDGPU.has_rocm_gpu()))'
```

On an AMD test machine, run the complete numerical suite followed by the shared
AMDGPU-versus-CPU benchmark with:

```sh
julia --threads=auto --project=. scripts/validate_amdgpu.jl 1024 459 5
```

Metal is an optional weak dependency because Metal.jl only runs on Apple Silicon.
It is not installed or loaded by ordinary package use. In an application
environment on an M-series Mac with macOS 14 or newer, install Metal.jl and load
it before selecting the backend. Metal.jl 1.10 supports Julia 1.10 through 1.12.

```julia
using Pkg
Pkg.add("Metal")

using Metal, PopulationCartogramProjection
Metal.functional() || error("Metal is not functional")
```

Loading both packages activates `PopulationCartogramProjectionMetalExt`, which
supplies `Metal.MetalBackend()` to the same KernelAbstractions kernels. Without
Metal.jl, or before `using Metal`, `backend=:metal` reports that the extension is
not loaded rather than installing a package or changing backends silently.
Metal is a test-only extra, so `Pkg.test()` installs it and automatically loads
the extension on Apple Silicon; ordinary package installation still omits it.

## Automatic Eta And Sparse Output

`fit_mapping_auto` follows one warm-started continuation schedule and evaluates
progressively tighter candidate etas. It targets
`round(target_rows_multiplier * (sources + targets))` sparse rows, matching the
scratch workflow's size rule. For source-heavy larger countries this approaches
two retained targets per source with the default multiplier of two, so the tuner
selects tighter regularization where needed.

```julia
fitted = fit_mapping_auto(sources; backend=:cuda)
mapping = fitted.mapping
retention = fitted.source_retention
metadata = fitted.metadata
```

The default candidate list extends from `0.005` to `1e-7`. Candidates are
visited from high to low eta, equal row errors retain the earlier higher eta,
and evaluation stops after the first candidate at or below the row target. The
closest converged candidate visited is returned. Failed candidates remain in
metadata and do not stop continuation; selected-candidate and solver-final
fields remain separate when a later stage does not converge.

Sparse rows are selected in descending `source_share` order, including the row
that crosses `cumulative_share`. Retained shares are not renormalized.
After `minimum_neighbors` have been retained, `minimum_source_share` can stop
before the next smaller row even if the cumulative target has not been reached.
This is an explicit rule, unlike the scratch workflow's inert `min_weight`
setting. `source_retention` reports retained and dropped share, whether the
cumulative target was achieved, and the truncation reason for every source.
Metadata reports population-weighted retained and dropped mass. Candidate
counting and final extraction use the same deterministic host implementation.
Metadata also records the per-run spatial transform and cost normalization.

## Real UK H3 Check

The full Kontur and Natural Earth Arrow inputs remain external and ignored. With
those files in their existing `make-lookup-table/population-data/` locations,
build a cached canonical UK extract without loading either complete table into a
DataFrame:

```sh
julia scripts/extract_country_h3.jl 826 6
```

This uses `clickhouse local` to reproduce the scratch workflow's exact H3 join,
parent population sum, and modal country assignment. Parent resolutions from 0
through the source resolution of 8 are supported. The script pins the
`h3ToGeo` coordinate order and validates IDs, resolution, country code,
coordinates, population, and uniqueness before publishing its output. The
resulting ignored `country-826-res6.arrow` has 8,346 unique sources, population
66,956,569, and is about 197 KiB.

Run the bounded package-versus-scratch migration oracle on the 8,346 by 459
native UK problem:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  make-lookup-table/compare_package_auto.jl
```

On the GTX 1080 Ti, after warming both CUDA paths:

| Implementation | Selected eta | Rows | Marginal error | Retained mass | Time |
|---|---:|---:|---:|---:|---:|
| Package | `5e-5` | 19,539 | 0.00105 | 99.770% | about 1.2 s |
| Scratch | `1e-5` | 18,616 | 0.00577 | 99.747% | about 1.5 s |

Prepared costs differ by at most `1.79e-7`, source masses by `9.31e-10`, and
target masses are identical. Dominant target cells agree for 96.15% of sources.
The eta difference is expected: the package tunes against normalized,
deterministic source shares, while the scratch GPU counter uses source-relative
mass from a loosely converged plan. No all-country population matching is run.

## Intel Gen9 Setup

Intel UHD 620 and other Gen9 GPUs require Intel's legacy compute runtime. On
Arch Linux:

```sh
paru -S intel-compute-runtime-legacy-bin
```

The package installs its Level Zero driver with a legacy suffix. Point the
oneAPI loader to it when launching Julia:

```sh
export ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
julia --project=. -e 'using oneAPI; oneAPI.versioninfo()'
```

`oneAPI.versioninfo()` should list the Intel GPU and `oneAPI.functional()`
should return `true`. Use the same environment variable for tests and examples:

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  julia --project=. -e 'using Pkg; Pkg.test()'
```

This setup has been verified with an Intel UHD 620 and
`intel-compute-runtime-legacy-bin` 24.35.30872.36. No additional system OpenCL
package is required for the oneAPI path.

## Backend Benchmark

The benchmark uses identical generated problems and solver options for every
enabled backend. CUDA and AMDGPU measurements are explicitly synchronized; CPU
is opt-in:

```sh
julia --threads=auto --project=. benchmark/compare_solvers.jl 1024 1024 5
```

The arguments are source count, target count, and repetitions. Compilation is
warmed before timings are recorded. Timings cover an end-to-end solver call,
including validation, allocation, host/device copies, convergence checks, and
the final dual transfer; they are not kernel-only timings. Reported allocations
are host allocations; the accelerator storage estimate is printed separately.

Include the CPU path explicitly:

```sh
BENCHMARK_CPU=true julia --threads=auto --project=. benchmark/compare_solvers.jl 256 256 5
```

For `m` sources and `n` targets, the solver stores the Float32 cost matrix and
its transpose on the accelerator. Those two dense matrices require `8mn` bytes;
the masses, duals, and marginal buffers add approximately `12(m+n)` bytes. A
dense transport plan is not materialized.

### Recorded CUDA Comparison

The separate direct-CUDA baseline was removed after this comparison. This table
is an archival selection record, not an output the current KA-only benchmark can
regenerate. It reports median end-to-end times from nine order-alternated
repetitions on 2026-07-17; both implementations used identical generated inputs
with seed `20260716` and identical convergence histories.

Hardware and software: NVIDIA GeForce GTX 1080 Ti (`sm_61`, 11 GiB), driver
570.211.01, Julia 1.12.1, CUDA.jl 6.2.1, and KernelAbstractions 0.9.42.

| Sources x targets | Direct CUDA | KA CUDA | KA/direct |
|---:|---:|---:|---:|
| 64 x 256 | 2.7 ms | 2.9 ms | 1.068 |
| 256 x 2,268 | 10.3 ms | 11.4 ms | 1.103 |
| 1,024 x 9,834 | 97.4 ms | 98.6 ms | 1.012 |
| 4,096 x 4,096 | 154.9 ms | 147.8 ms | 0.954 |

The portable path added about 0.2-1.2 ms on the representative rectangular
problems and was faster on the largest square problem. That cost did not justify
maintaining a second CUDA implementation, so KernelAbstractions is the retained
solver for CUDA, AMDGPU, Metal, oneAPI, and CPU.

The package bundles the small OWID grid in `data/cartogram.csv`; ordinary use
does not require the large Kontur or Natural Earth H3 datasets.

## Current Limits

- `fit_mapping` currently handles one country at a time.
- CUDA, AMDGPU, Metal, oneAPI, and CPU use one portable kernel implementation;
  Metal is activated through a weak-dependency extension.
- `fit_mapping` is dense; `fit_mapping_auto` returns sparse output and retention
  diagnostics.
- Spatial scaling is fitted independently from each run's source extrema and
  target grid bounds.
- Antimeridian-spanning and disconnected geographies have no dedicated policy.
- Rendering has not yet been moved into the package.

The existing `make-lookup-table/` workspace retains the large H3 workflow while
it is migrated to the package solver.
