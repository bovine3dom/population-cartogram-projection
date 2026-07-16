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

The default direct CUDA implementation requires an NVIDIA CUDA-capable GPU and
functional CUDA driver. Check availability with:

```sh
julia --project=. -e 'using CUDA; println(CUDA.functional())'
```

Then fit the included five-source synthetic example with the direct CUDA
implementation:

```julia
using CSV, DataFrames, PopulationCartogramProjection

sources = CSV.read("test/fixtures/synthetic_sources.csv", DataFrame)
mapping = fit_mapping(sources)
first(mapping, 5)
```

Three KernelAbstractions paths are available while backend performance is
evaluated:

```julia
cuda_mapping = fit_mapping(sources; implementation=:ka_cuda)
intel_mapping = fit_mapping(sources; implementation=:ka_oneapi)
cpu_mapping = fit_mapping(sources; implementation=:ka_cpu)
```

The default remains the direct CUDA implementation. The comparison paths share
input normalization, continuation, convergence, result construction, and
mapping extraction with it. The CPU path runs the same KernelAbstractions
kernels; there is no separately maintained CPU solver.

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

The benchmark uses identical generated problems and solver options. On an
NVIDIA machine it compares direct CUDA with KernelAbstractions CUDA; it also
runs oneAPI when available:

```sh
julia --project=. benchmark/compare_solvers.jl 1024 1024 5
```

The arguments are source count, target count, and repetitions. Compilation is
warmed before timings are recorded. A CUDA ratio is reported only when the two
implementations have matching convergence histories.

Include the CPU path explicitly:

```sh
BENCHMARK_CPU=true julia --project=. benchmark/compare_solvers.jl 256 256 5
```

The package bundles the small OWID grid in `data/cartogram.csv`; ordinary use
does not require the large Kontur or Natural Earth H3 datasets.

## Current Limits

- `fit_mapping` currently handles one country at a time.
- Direct CUDA and portable CUDA/oneAPI/CPU implementations are temporarily
  retained for correctness and performance comparison.
- Output is dense; sparse extraction is not yet part of this path.
- Source coordinates are scaled from their bounding box to the country's OWID
  grid bounding box. This is an explicit modelling limitation under review.
- Rendering and projection of additional values have not yet been moved into
  the package.

The existing `make-lookup-table/` workspace retains the large H3 workflow while
it is migrated to the package solver.
