# Population Cartogram Projection

For a single-country run with Kontur H3 data and oneAPI, see the
[UK H3 workflow](examples/uk-h3/readme.md) and its
[measured results and runtime estimates](examples/uk-h3/results.md).

A small Julia package that distributes one country's positive geographic source
values over a balanced cartogram with entropic optimal transport.

## Scope

Keep the solver small, but retain a complete example workflow.
The core owns transport weights and accepts a caller-supplied KernelAbstractions
backend. Examples and scripts own data preparation, H3, file formats, city labels,
and rendering. Their dependencies stay outside the root project.

The UK trial showed a gap in the documented workflow, not a need to restore the
removed country, projection, and persistence APIs. Keep preparation and export
steps tested and documented outside the core.

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
separately.

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
