# Population Cartogram Projection

A small Julia package that distributes one country's positive geographic source
values over a balanced cartogram with entropic optimal transport.

## Interface

The cartogram is a table containing:

```text
x, y
```

The source table contains:

```text
x, y, value, id
```

`value` is both the positive transport mass and the quantity being distributed.
`id` is opaque and may be a string, integer, or `UInt64` H3 index. Run countries
separately; country filtering and code reconciliation are intentionally outside
the package.

```julia
using DataFrames
import KernelAbstractions as KA
using PopulationCartogramProjection

cartogram = DataFrame(x=[0, 1, 2], y=[0, 0, 0])
sources = DataFrame(
    id=["west", "east"],
    x=[-1.2, 1.7],
    y=[51.0, 50.2],
    value=[40.0, 60.0],
)

mapping = distribute(cartogram, sources; backend=KA.CPU())
```

The result contains exactly:

```text
x, y, id, weight, weight_mean
```

For source `i` and cartogram cell `j`:

```text
transported_value[i,j] = source.value[i] * weight[i,j]

weight[i,j] = transported_value[i,j] / source.value[i]

weight_mean[i,j] = transported_value[i,j] /
                   sum(transported_value[:,j])
```

`weight` is source-normalized. `weight_mean` is cartogram-cell-normalized and
sums to one over the retained contributors to each represented cell.

## Backends

The caller supplies an instantiated
[`KernelAbstractions.Backend`](https://github.com/JuliaGPU/KernelAbstractions.jl).
This package does not import or depend on accelerator vendors:

```julia
using CUDA
mapping = distribute(cartogram, sources; backend=CUDA.CUDABackend())

using AMDGPU
mapping = distribute(cartogram, sources; backend=AMDGPU.ROCBackend())

using Metal
mapping = distribute(cartogram, sources; backend=Metal.MetalBackend())

# on my old thinkpad, julia needs to be launched with
# export ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
using oneAPI
mapping = distribute(cartogram, sources; backend=oneAPI.oneAPIBackend())
```

The UK example below deliberately uses CPU; the larger France IRIS and Europe
entry points use CUDA. The underlying `distribute` API accepts another backend,
but using ROCm, Metal, or oneAPI also requires adding that vendor package to the
consumer environment, adapting the concrete calls, and removing the Europe
entry point's CUDA preflight.

The implementation uses only generic KernelAbstractions allocation, copying,
synchronization, and kernel-launch APIs. Backends must support Float32, local
memory, and a 256-item workgroup.

## Automatic Eta

`distribute` traverses one descending eta continuation schedule. Sinkhorn duals
and device buffers remain warm between stages. At candidate etas it reconstructs
the sparse output on the host, tracks the candidate closest to the output-row
target, and stops after the first eligible candidate at or below that target:

```text
target_rows_multiplier * (number of sources + number of cells)
```

The principal controls are:

```julia
mapping = distribute(
    cartogram,
    sources;
    backend,
    cost_mode=:dense,
    truncation_tolerance=1e-6,
    truncation_eta=0.001,
    candidate_etas=Float32[0.005, 0.002, 0.001, 0.0005],
    target_rows_multiplier=2,
    cumulative_weight=0.995,
    minimum_weight=0,
    minimum_cells=1,
    maximum_cells=nothing,
    minimum_retained_value=0,
)
```

`cost_mode=:matrix_free` selects an all-pairs, non-truncated solver for the
default `cost_power=2`. Accelerator backends stream `32 x 8` coordinate tiles
through local memory; CPU uses a threaded matrix-free reduction. Both avoid
materializing the source-by-cell cost matrix, so working cost storage is linear
in the source and cell counts. High/low `Float32` coordinate pairs preserve
small displacements without requiring backend `Float64`, but operation order is
not bitwise identical to dense cost construction. Dense mode remains the
default and numerical oracle while backend crossover points are measured.

`cost_mode=:truncated` is an opt-in accelerator mode over the same squared-cost
problem. It Morton-orders points into 32-point leaves and 256-point coarse
blocks, refreshes dual maxima before each truncated half-step, and skips blocks
using conservative point-to-box cost bounds. The first iteration at every eta,
all stages above `truncation_eta`, and every convergence marginal check remain
all-pairs. `truncation_tolerance` bounds omitted row-normalizer mass for each
truncated reduction in real arithmetic; it is not a final transport-error or
convergence guarantee. CPU backends fall back to exact matrix-free solving.

The default `truncation_eta=0.001` reflects the measured France factor 3
crossover on the tested oneAPI backend. Smaller problems can remain slower even
below that threshold. This solver truncation is independent of the sparse output
selection described below.

Sparse `weight` values are not renormalized. Their sum records the retained
fraction of each source, while `weight_mean` is calculated from retained rows and
therefore still sums to one for each represented cartogram cell.

## Spatial Policy

For each invocation, source longitude is linearly scaled to the cartogram's
x-range. Negated source latitude is linearly scaled to its y-range because the
OWID cartogram axis points downward. Distances are measured in cartogram-step
units, normalized by their maximum, and squared by default.

This extrema transform is intentionally simple. Outliers affect every source,
and disconnected or antimeridian-spanning geographies should be prepared as
separate inputs by the caller.

## Examples

The consumer environment contains CSV, H3, rendering, and accelerator packages:

```sh
julia +1.12.1 --project=make-lookup-table -e 'using Pkg; Pkg.instantiate()'
```

Run the synthetic CPU example:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/regional_centres.jl
```

Run the cached UK H3 workflow:

```sh
julia scripts/extract_country_h3.jl 826 6
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/uk_h3.jl
```

Run the France IRIS workflow:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/france/iris_population.jl 1
```

Run the country-by-country Europe workflow at native factor 1:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/europe/europe.jl
```

The first run uses `clickhouse local` to build a reusable resolution-6 H3 source
cache, then writes an Arrow mapping with split `index_lower`/`index_upper` H3
identifiers. See [`examples/europe/readme.md`](examples/europe/readme.md).

The examples own H3 validation, country filtering, cartogram loading and
subdivision, secondary projections, city placement, persistence, and rendering.
None are package dependencies.

## Tests

```sh
julia +1.12.1 --threads=auto --project=. -e 'using Pkg; Pkg.test()'
```

The France adapter checks require the derived `examples/france/iris-population.csv`
and `examples/france/iris-cities.csv` fixtures described in its example readme.

The suite checks input validation, conservation, both weight normalizations,
warmed automatic eta selection, opaque `UInt64` IDs, caller-provided backends,
example-owned UK H3 and France IRIS input adapters, and Europe orchestration and
split-index compatibility.

## oneAPI Benchmark

Instantiate the isolated benchmark environment, then compare the dense and
matrix-free paths. The final argument is the fixed iteration cap:

```sh
julia +1.12.1 --project=benchmark -e 'using Pkg; Pkg.instantiate()'
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  julia +1.12.1 --threads=auto --project=benchmark \
  benchmark/compare_solvers.jl 1024 1024 5 50
```

Use the checked-in France IRIS fixtures at subdivision factor 1 with:

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  julia +1.12.1 --threads=auto --project=benchmark \
  benchmark/compare_solvers.jl france 1 5 50
```

Set `BENCHMARK_TRUNCATED=true` and `BENCHMARK_ETA=0.0001` to compare the
experimental hierarchy against exact matrix-free solving. Use `france-mf` for
factor 6 so the unsafe dense allocation is not attempted. To benchmark
truncation above the default cutoff, also raise `BENCHMARK_TRUNCATION_ETA`; for
example, set both eta variables to `0.005`.

Preparation time, warm solver timing, host allocations, convergence diagnostics,
and theoretical host-plus-device cost storage are reported separately. See the
[recorded Intel UHD 620 results](benchmark/results.md).
