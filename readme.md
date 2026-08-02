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
