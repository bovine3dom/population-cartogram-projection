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

using oneAPI
mapping = distribute(cartogram, sources; backend=oneAPI.oneAPIBackend())
```

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
    candidate_etas=Float32[0.005, 0.002, 0.001, 0.0005],
    target_rows_multiplier=2,
    cumulative_weight=0.995,
    minimum_weight=0,
    minimum_cells=1,
    maximum_cells=nothing,
    minimum_retained_value=0,
)
```

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
  examples/uk_h3.jl cuda
```

Run the France IRIS workflow:

```sh
julia +1.12.1 --threads=auto --project=make-lookup-table \
  examples/france/iris_population.jl cuda 1
```

The examples own H3 validation, country filtering, cartogram loading and
subdivision, secondary projections, city placement, persistence, and rendering.
None are package dependencies.

## Tests

```sh
julia +1.12.1 --threads=auto --project=. -e 'using Pkg; Pkg.test()'
```

The suite checks input validation, conservation, both weight normalizations,
warmed automatic eta selection, opaque `UInt64` IDs, caller-provided backends,
and example-owned UK H3 and France IRIS input adapters.
