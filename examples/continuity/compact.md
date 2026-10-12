# Compact continuity plans

This is an experimental alternative to the dense research solver. It does not
change the production `distribute` API. Use `country(...; dense=false)` and
`run_case(...; compact=true)` to avoid persistent dense cost and transport matrices.
The device backend must still be supplied by the caller. A bounded active-country
cost cache is optional, as described below.

## Representation

Keep source and target dual vectors, three geographic force values per target,
and the accepted update history. For a proximal update, let `lambda` be the
proximal weight and `tau = eta + lambda`. Its undamped plan is

```text
S[i,j] = exp(u[i] + v[j] - C[i,j]/tau) *
         max(P_old[i,j], floatmin(Float64))^(lambda/tau)
P_new = (1-damping)*P_old + damping*S
```

The cost is the original geometric cost plus the geographic force term. Evaluate
this recurrence in log space. Keep each accepted damping value in the history.
This represents the same proximal term and mixture as the dense method. It does
not replace a mixture with an averaged dual vector or prune transport entries.

Stored arrays grow with `(sources + targets) × accepted updates`, not with
`sources × targets`. History evaluation becomes more expensive as its depth
grows. This is a memory improvement, not a guarantee of faster inner solves.

## Reductions and checks

KernelAbstractions evaluates costs and history entries directly on the backend.
Online log-sum-exp avoids evaluating the history twice per reduction. The solver
can cache the current country's cost on the device, with a default limit of
512 MiB. This avoids repeated history evaluation for countries that fit the
budget. Larger countries use implicit costs. No dense host cost or transport
plan is created. Set `compact_cache_bytes=0` in `run_case`, or `cache_bytes=0` in
`compact_sinkhorn`, to disable this cache. Kernel launches are split into bounded
output ranges. The implicit pair budget decreases as history depth grows. This
limits long kernels on the Intel legacy driver. One complete reduction row is
the minimum launch size. Each check
first uses device reductions. A candidate close to convergence is checked in
Float64 host blocks. Normalize its source rows exactly and check target L1 error
and maximum relative error before accepting it.

`compact_sinkhorn` performs one fixed-temperature solve. The research runner uses
`compact_solve`: first try up to 1,000 iterations, then use temperature factors
16, 8, 4, 2, and 1 if needed. Scale the full effective temperature `eta + lambda`;
keep the prior plan and proximal weight fixed. Each stage checks the original
mass tolerance. Only the last stage becomes a candidate, with the requested
temperature. Earlier stages supply dual initial values, not extra plan history.
A failed final solve raises an error. No dense or CPU fallback is used.

Calculate target moments, transport cost, and entropy in bounded host blocks.
Reuse moments and masses for unchanged countries. A damped mixture has linear
moments, masses, and base cost; its entropy is calculated from the actual mixture.
No full dense plan is needed for the continuity objective or its force gradient.

Host log and weight buffers are reused across blocks. Device launches are
synchronized in batches. Periodic garbage collection releases completed native
command lists on oneAPI; their large driver allocations are not visible to
Julia's normal heap-pressure check.

The block size defaults to one million source–target pairs. If the target count
exceeds that size, one full source row is the minimum block. Saved plans contain
cached statistics and can be read after loading `experiment.jl`.

## Tests

```sh
ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1 \
  CONTINUITY_GPU_TEST=1 OPENBLAS_NUM_THREADS=4 \
  julia --threads=4 --project=examples/uk-h3 test/compact.jl
```

Tests compare CPU and oneAPI results with dense solves. They include repeated
proximal updates, damped mixtures, source and target masses, objective values,
country-wise fitting, and saved plan files. Real-data performance results are
recorded separately in the performance work log.
