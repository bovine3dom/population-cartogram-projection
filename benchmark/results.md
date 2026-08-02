# Matrix-Free oneAPI Benchmark

Measured 2 August 2026 on an Intel UHD Graphics 620 (`0x5917`) with Julia
1.12.1, eight Julia threads, oneAPI.jl 2.7.2, KernelAbstractions.jl 0.9.42, and
the legacy Level Zero driver selected by:

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
```

Each warmed synthetic solve used one `eta=0.02` stage capped at 50 iterations, checked
marginals at iterations 1 and 50, and converged below `2e-6`. Timings include
internal solver allocation and host-device copies but exclude geometry
preparation, automatic-eta sparse statistics, final output reconstruction, and
JIT compilation. Solve columns are medians of five runs except for the largest
case, which uses three; preparation columns are single warmed samples.

| Sources x cells | Dense prep | Matrix-free prep | Dense solve | Matrix-free solve | Speedup | Dense cost storage | Matrix-free cost storage | Sampled weight delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 x 256 | 0.0051 s | 0.0049 s | 0.0466 s | 0.0283 s | 1.65x | 1 MiB | 0.016 MiB | `2.42e-8` |
| 1,024 x 1,024 | 0.0397 s | 0.0036 s | 0.1984 s | 0.1397 s | 1.42x | 16 MiB | 0.062 MiB | `6.54e-9` |
| 4,096 x 256 | 0.0563 s | 0.0066 s | 0.3196 s | 0.1476 s | 2.17x | 16 MiB | 0.133 MiB | `3.92e-8` |
| 256 x 4,096 | 0.0420 s | 0.0023 s | 0.3114 s | 0.1500 s | 2.08x | 16 MiB | 0.133 MiB | `1.61e-9` |
| 4,096 x 4,096 | 0.5279 s | 0.0200 s | 1.6773 s | 1.6504 s | 1.02x | 256 MiB | 0.250 MiB | `3.86e-9` |

Cost storage models peak explicitly materialized host and device cost state.
Dense mode holds the original cost, a temporary host transpose, and both device
orientations. Matrix-free mode holds host and device copies of eight high/low
coordinate vectors. Shared masses, duals, marginal buffers, runtime temporaries,
and returned output are excluded from both values.

The final column is the largest source-normalized weight difference for the
first, middle, and last source rows after the warmed dense and matrix-free
solves. It is more directly meaningful than comparing gauge-dependent duals.

Median Julia host allocations during the solve fell from 4.72-4.74 MiB to
1.80-1.82 MiB for the one-million-pair cases, and from 64.76 MiB to 1.84 MiB for
the 16.8-million-pair case. These are allocation totals, not peak resident or
device memory measurements.

The matrix-free preparation still evaluates every pair once to preserve the
observed maximum-distance normalization, but retains only one maximum per target.
The speedup is for the warmed fixed-eta internal solver path, combining setup,
transfer, tile reuse, and fused reduction effects; it is not a kernel-only or
end-to-end `distribute` speedup. Sparse reconstruction still scans and sorts
full source rows, and a fully dense requested output can still contain `ST`
rows. No CUDA result was collected on this system.

## France IRIS

The same harness loaded the checked-in metropolitan France fixture with 48,416
IRIS sources. Factor 1 used 50 iterations and five repetitions; factor 3 used 20
iterations and three repetitions to limit the much larger dense run.

| Factor | Sources x cells | Dense prep | Matrix-free prep | Dense solve | Matrix-free solve | Speedup | Dense cost storage | Matrix-free cost storage | Sampled weight delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 48,416 x 438 | 0.8204 s | 0.0841 s | 4.2397 s | 2.5662 s | 1.65x | 323.581 MiB | 1.491 MiB | `2.35e-8` |
| 3 | 48,416 x 3,942 | 6.8197 s | 0.1908 s | 9.6123 s | 8.1854 s | 1.17x | 2,912.229 MiB | 1.598 MiB | `2.60e-9` |

The strict benchmark tolerance was `2e-6`. Neither capped run converged within
its iteration budget, but dense and matrix-free marginal errors agreed closely:
`4.1432e-5` versus `4.1422e-5` at factor 1, and `0.00535755` versus `0.00535750`
at factor 3. These remain fixed-work throughput comparisons, not timings of the
default automatic-eta continuation.

Median Julia host allocation totals during the solve fell from 81.79 MiB to
1.97 MiB at factor 1 and from 728.72 MiB to 1.23 MiB at factor 3. These totals
are not peak resident or oneAPI device-memory measurements.

Factor 6 dense mode was not attempted: its modeled 11.38 GiB cost state exceeded
safe available memory on this host, while matrix-free coordinate cost state
is approximately 1.96 MiB. The legacy oneAPI watchdog required splitting each
763-million-pair reduction into launches capped near 200 million pairs. With
that exact chunking, a 20-iteration matrix-free solve took 32.822 seconds and
ended at marginal error `0.00524762`.

## Dual-Aware Truncation

The experimental two-level hierarchy uses Morton-ordered 256-point coarse blocks
over 32-point leaves and `truncation_tolerance=1e-6`. The first iteration at each
eta and every marginal audit are exact all-pairs operations. These cold,
single-eta runs therefore measure a conservative hybrid rather than an ideal
sparse-only kernel. All rows set `BENCHMARK_TRUNCATED=true` and
`BENCHMARK_ETA` to the tabulated eta; the `5e-3` row also set
`BENCHMARK_TRUNCATION_ETA=0.005`. Factors 1, 3, and 6 used respectively
`france 1 5 20`, `france 3 3 10`, and `france-mf 6 3 5`.

| Factor | Eta | Iterations | Exact matrix-free | Truncated | Speedup | Main pairs retained | Total pair-work upper bound | Sampled weight delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `1e-4` | 20 | 1.0999 s | 1.1685 s | 0.94x | 26.4% | 39.6% | `7.57e-8` |
| 3 | `5e-3` | 10 | 4.6505 s | 5.9986 s | 0.78x | 69.8% | 77.7% | `5.74e-9` |
| 3 | `1e-3` | 10 | 4.5762 s | 4.4304 s | 1.03x | 33.7% | 50.6% | `1.10e-8` |
| 3 | `1e-4` | 10 | 4.5615 s | 3.3795 s | 1.35x | 18.8% | 39.4% | `1.17e-7` |
| 6 | `1e-4` | 5 | 9.7276 s | 6.8193 s | 1.43x | 13.1% | 50.4% | `6.54e-8` |

For France factor 3 on this backend, this places the crossover near eta `1e-3`;
the default keeps broader stages exact. Factor 1 remains too small to amortize
hierarchy traversal even at `1e-4`. Truncated coordinate, hierarchy,
dual-maximum, and counter state is still linear: approximately 2.67 MiB,
2.86 MiB, and 3.51 MiB for France factors 1, 3, and 6 respectively, excluding
shared solver vectors.

"Main pairs retained" covers only truncatable Sinkhorn updates. The total upper
bound adds exact eta-boundary updates, exact marginal audits, and one 32-pair
witness leaf per output and compares that sum with the equivalent all-pairs
workload. It is an upper bound because a final witness leaf can contain fewer
than 32 points. Weight deltas are maxima over the first, middle, and last source.

The runs were not converged because the low-eta cold starts intentionally used
short fixed iteration caps; production uses warm eta continuation and the normal
exact marginal stopping criterion.
