# Continuity solver performance

These measurements use KernelAbstractions and oneAPI on the Intel HD Graphics
P630, with Julia 1.12.7, eight Julia threads, and four BLAS threads. The machine
has 62 GiB of RAM. No core solver or production dataset was changed.

## Large regional test

Inputs: Angola, DRC, and Zambia, Kontur H3-6, OWID subdivision factor 2.
There are 66,925 sources, 4,304 targets, and 119,214,388 within-country pairs.
Both modes use the same objective, three update passes, eta 0.002, proximal
weight 0.1, and target L1 tolerance 0.0001. This fixed eta is a performance test
setting, not a tuned H3-6 quality recommendation.

| Measurement | Dense | Compact |
| --- | ---: | ---: |
| Cold fit, including compilation | 562 s | 437 s |
| Warm fit | 476 s | 345 s |
| Peak process resident memory | 7.79 GiB | 2.17 GiB |
| Stored plans | 954 MB | 7.54 MB |
| Warm cumulative Julia allocations | 108.4 GB | 0.875 GB |
| Final objective | 0.2956169 | 0.2956181 |
| Cross-border RMS | 292.7545 km | 292.7534 km |

The warm compact fit is 28% faster and uses 3.6 times less peak resident memory.
Peak process memory covers preparation, the cold fit, and the warm fit in one
process. It does not measure all GPU memory. Cumulative allocations are not peak
memory. These are individual runs, not confidence intervals. Input preparation
is separate from fit time and took about 31 seconds in each mode.

The compact run uses a 512 MiB active-country device cost cache. It stores no
dense host costs or transport plans. An uncached one-pass test also completed:
724 seconds including compilation. The uncached mode saves cost-cache space,
but repeats cost evaluation and is slower. It is not the preferred mode when
the active cost fits the cache budget.

Independent checks recompute compact masses and moments from bounded blocks.
Source and target checks pass. The maximum final target-centre difference from
dense was 355 metres; plan L1 differences were below 0.00037 per country. Thus the numerical results are close, not
identical. Fold and border defects remain. Lower runtime does not establish
better map quality.

## Changes

- Store dual variables and update history instead of full transport matrices.
- Retain both proximal terms and damped mixtures; do not average duals.
- Reuse bounded host buffers for mass, moment, and entropy calculations.
- Cache only the active country's cost, with an explicit memory budget.
- Bound device launch sizes and queued work.
- Collect completed native command lists periodically. Their driver allocations
  are not visible to Julia's normal heap-pressure check.
- Use typed statistics and column views for border and fold calculations.
- Retry difficult solves with decreasing temperatures. Keep the original final
  temperature, proximal term, and mass limits.
- Use bounded sparse primal refinement when Float32 rounding prevents the
  reconstructed plan from passing its mass check. Check the full implicit plan.
  Fall back to refinement in the existing dense device cache when needed.
- Select planet poses at H3-4, then check each proposed angle at native H3-5.
  This reduces pose-search work, but can change the selected initial solution.

The host-only border-force calculation fell from 78.2 ms to 1.73 ms per call
on the saved Africa case. This is not a full-solver speedup estimate. It was
measured separately. The table and final planet continuation use these changes.

## Sparse marginal refinement

A saved US H3-5 candidate has 71,174,732 source–target pairs. Both refinement
modes need 1,000 primal iterations and pass the full Float64 mass checks.
On a warm run, dense refinement takes 67.9 seconds. Sparse construction, upload,
and refinement together take 14.9 seconds, about 4.6 times faster. Sparse weights
and indices use 8.49 MB for 522,072 retained pairs, versus 284.7 MB for dense
weights. Target L1 error is 0.0000797 in both modes. Maximum relative source
error is below 0.000000000000003.

This is a refinement-stage comparison, not a full fit timing. It excludes an
existing cost cache, which remains allocated during sparse refinement. The
combined sparse and cost-cache storage must fit the configured cache budget.
The result comes from `benchmark-sparse-primal-paired.log` in
`output/continuity-performance`. The regional table uses the final code, but
that regional case does not need sparse refinement.

## Reproduce

Use new output paths. From the repository root:

```sh
export ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1
export OPENBLAS_NUM_THREADS=4
export CONTINUITY_BENCH_WARM=1
export CONTINUITY_COMPACT_CACHE_BYTES=536870912
python examples/continuity/measure_process.py output/new-compact.time.json \
  julia --threads=8 --project=examples/uk-h3 \
  examples/continuity/benchmark_compact.jl \
  output/continuity/africa-kontur6 6 2 compact 3 output/new-compact 24 180 894
```

Repeat with `dense` and a different output path. Run the modes in sequence,
not at the same time. Set `CONTINUITY_COMPACT_CACHE_BYTES=0` for the uncached test.
Compare their `fit` directories with `examples/continuity/compare_compact.jl`.
The benchmark saves code snapshots, settings, timings, and diagnostics.

The table uses `output/continuity-performance/africa6-dense-v6` and
`output/continuity-performance/africa6-cached-v6`, both at commit `f7dc433`. See the
[work log](continuity-performance-work-log.md) for failed driver tests and fixes.
See [compact plans](../examples/continuity/compact.md) for the representation and
[planet instructions](../examples/continuity/planet.md) for publication.

## Limits

Compact storage is linear in source count, target count, and update depth.
Pair evaluation still grows with source count times target count. Mixture
history makes implicit evaluation more expensive as accepted updates accumulate.
The cache budget is not a total process-memory limit. No measured whole-planet
H3-6 runtime is available yet; do not extrapolate it from plan size alone.

Sparse primal refinement is implemented. The main log-domain iterations still
use all pairs. A possible next step is an adaptive sparse log-domain kernel.
Use candidate pairs for iterations, then check the full implicit plan in bounded
blocks. Expand the candidate set when the full check fails. This extension is
not implemented or benchmarked here. Do not use geometric distance
alone to exclude pairs: the force and proximal terms can change which pairs
are important.

Schmitzer's [stabilized sparse scaling paper](https://arxiv.org/abs/1610.06519)
combines log-domain stabilization, temperature scaling, adaptive kernel
truncation, and coarse-to-fine solves. It is a relevant starting point, not a
performance guarantee for this continuity objective.
