# Compact continuity plans

This is an experimental alternative to the dense research solver. It does not
change the production `distribute` API. Use `country(...; dense=false)` and
`run_case(...; compact=true)` to avoid dense cost and transport matrices.
The device backend must still be supplied by the caller.

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
Online log-sum-exp avoids evaluating the history twice per reduction. Each check
first uses device reductions. A candidate close to convergence is checked in
Float64 host blocks. Normalize its source rows exactly and check target L1 error
and maximum relative error before accepting it.

Calculate target moments, transport cost, and entropy in bounded host blocks.
Reuse moments and masses for unchanged countries. A damped mixture has linear
moments, masses, and base cost; its entropy is calculated from the actual mixture.
No full dense plan is needed for the continuity objective or its force gradient.

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
