# oneAPI Benchmark

Measured 2 August 2026 on an Intel UHD Graphics 620 (`0x5917`) with Julia
1.12.1, eight Julia threads, oneAPI.jl 2.7.2, KernelAbstractions.jl 0.9.42, and
the legacy Level Zero driver selected by:

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
```

The benchmark compares exact all-pairs matrix-free Sinkhorn with the package's
default accelerator path. Both use the same prepared geometry, initial duals,
fixed `eta=1e-4`, exact marginal checks, and iteration cap. Hybrid timings
include construction and transfer of the Morton hierarchy.

| France factor | Sources x cells | Iterations | Preparation | Exact | Default hybrid | Speedup | Exact storage | Hybrid storage | Sampled weight delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 48,416 x 438 | 20 | 0.0578 s | 1.6772 s | 1.6823 s | 1.00x | 1.491 MiB | 1.923 MiB | `3.90e-8` |
| 3 | 48,416 x 3,942 | 10 | 0.1293 s | 7.0032 s | 4.4018 s | 1.59x | 1.598 MiB | 2.061 MiB | `4.66e-8` |
| 6 | 48,416 x 15,768 | 5 | 0.2063 s | 14.6967 s | 10.0105 s | 1.47x | 1.959 MiB | 2.526 MiB | `2.66e-8` |

Solve columns are medians of three warmed runs. Weight deltas are maxima over
the first, middle, and last source. These deliberately short cold-eta solves did
not converge; paired exact marginal errors agreed within `4e-8`. They measure
fixed-work throughput rather than the public automatic continuation.

Reproduce a row with:

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  BENCHMARK_ETA=0.0001 julia --threads=8 --project=benchmark \
  benchmark/compare_solvers.jl france FACTOR 3 ITERATIONS
```
