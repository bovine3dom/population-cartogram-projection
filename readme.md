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

## Try It

Instantiate the root project and run the tests:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

Numerical tests run for every functional accelerator backend that is available.

The default `:cuda` backend requires an NVIDIA CUDA-capable GPU and functional
CUDA driver. Check availability with:

```sh
julia --project=. -e 'using CUDA; println(CUDA.functional())'
```

The `:amdgpu` backend requires a supported AMD GPU and functional ROCm/HIP
installation. AMDGPU.jl currently documents ROCm 6.0 or newer. Check both the
software stack and device detection with:

```sh
julia --project=. -e 'using AMDGPU; AMDGPU.versioninfo(); println((AMDGPU.functional(), AMDGPU.has_rocm_gpu()))'
```

Then fit the included five-source synthetic example:

```julia
using CSV, DataFrames, PopulationCartogramProjection

sources = CSV.read("test/fixtures/synthetic_sources.csv", DataFrame)
mapping = fit_mapping(sources)
first(mapping, 5)
```

Select a backend explicitly when needed:

```julia
cuda_mapping = fit_mapping(sources; backend=:cuda)
amd_mapping = fit_mapping(sources; backend=:amdgpu)
intel_mapping = fit_mapping(sources; backend=:oneapi)
cpu_mapping = fit_mapping(sources; backend=:cpu)
```

All four backends run the same KernelAbstractions row, column, and marginal
kernels. Backend selection never falls back silently, and there is no separately
maintained CPU or direct-CUDA solver.

The CPU backend requires no system setup and is intended for fallback-sized
regional problems. Its 256-workitem reductions are GPU-oriented and allocate
more than a dedicated CPU algorithm would, so it is not intended to replace GPU
execution for large H3 workloads.

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
solver for CUDA, AMDGPU, oneAPI, and CPU.

The package bundles the small OWID grid in `data/cartogram.csv`; ordinary use
does not require the large Kontur or Natural Earth H3 datasets.

## Current Limits

- `fit_mapping` currently handles one country at a time.
- CUDA, AMDGPU, oneAPI, and CPU use one portable kernel implementation.
- `fit_mapping` is dense; `fit_mapping_auto` returns sparse output and retention
  diagnostics.
- Source coordinates are scaled from their bounding box to the country's OWID
  grid bounding box. This is an explicit modelling limitation under review.
- Rendering and projection of additional values have not yet been moved into
  the package.

The existing `make-lookup-table/` workspace retains the large H3 workflow while
it is migrated to the package solver.
