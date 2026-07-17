# Population Cartogram Projection

Experimental Julia code for mapping population-weighted geographic centres onto
the [Our World in Data population cartogram](https://owid.github.io/cartograms/).

The first supported path accepts one country's source table with these columns:

```text
id, population, x, y, country_code
```

`id` is opaque and can be an H3 index, NUTS code, ONS code, IRIS code, or another
stable identifier. The result is a dense fractional mapping:

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
intel_mapping = fit_mapping(sources; backend=:oneapi)
cpu_mapping = fit_mapping(sources; backend=:cpu)
```

All three backends run the same KernelAbstractions row, column, and marginal
kernels. Backend selection never falls back silently, and there is no separately
maintained CPU or direct-CUDA solver.

The CPU backend requires no system setup and is intended for fallback-sized
regional problems. Its 256-workitem reductions are GPU-oriented and allocate
more than a dedicated CPU algorithm would, so it is not intended to replace GPU
execution for large H3 workloads.

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
enabled backend. CUDA measurements are explicitly synchronized; CPU is opt-in:

```sh
julia --project=. benchmark/compare_solvers.jl 1024 1024 5
```

The arguments are source count, target count, and repetitions. Compilation is
warmed before timings are recorded. Timings cover an end-to-end solver call,
including validation, allocation, host/device copies, convergence checks, and
the final dual transfer; they are not kernel-only timings. Reported allocations
are host allocations; the accelerator storage estimate is printed separately.

Include the CPU path explicitly:

```sh
BENCHMARK_CPU=true julia --project=. benchmark/compare_solvers.jl 256 256 5
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
solver for CUDA, oneAPI, and CPU.

The package bundles the small OWID grid in `data/cartogram.csv`; ordinary use
does not require the large Kontur or Natural Earth H3 datasets.

## Current Limits

- `fit_mapping` currently handles one country at a time.
- CUDA, oneAPI, and CPU use one portable kernel implementation.
- Output is dense; sparse extraction is not yet part of this path.
- Source coordinates are scaled from their bounding box to the country's OWID
  grid bounding box. This is an explicit modelling limitation under review.
- Rendering and projection of additional values have not yet been moved into
  the package.

The existing `make-lookup-table/` workspace retains the large H3 workflow while
it is migrated to the package solver.
