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
and maximum relative error before accepting it. After a failed host check, check
again when the device residual improves by 10%, after 500 iterations, or at the
iteration limit. This avoids repeated full-plan checks at a Float32 rounding
floor. No plan is accepted without the full check.

`compact_sinkhorn` performs one fixed-temperature solve. The research runner uses
`compact_solve`: first try up to 1,000 iterations, then use temperature factors
16, 8, 4, 2, and 1 if needed. Scale the full effective temperature `eta + lambda`;
keep the prior plan and proximal weight fixed. Each stage checks the original
mass tolerance. Only the last stage becomes a candidate, with the requested
temperature. Earlier stages supply dual initial values, not extra plan history.
A failed final solve raises an error. No dense host plan or CPU solver fallback
is used. Reuse the cost workspace across temperature stages: the force, prior,
and proximal weight stay fixed. Restore the cached cost if dense refinement
overwrote it. Do not change these inputs in a stage callback.

Calculate target moments, transport cost, and entropy in bounded host blocks.
Reuse moments and masses for unchanged countries. A damped mixture has linear
moments, masses, and base cost; its entropy is calculated from the actual mixture.
No full dense plan is needed for the continuity objective or its force gradient.

Strong forces can cause a Float32 device result to fail the Float64 mass check.
After 1,000 iterations, with a nonzero cache budget, try sparse refinement when
the device target L1 residual is at most ten times the tolerance and maximum
relative error is at most 1%. These are refinement-entry limits, not acceptance limits. Keep the
stricter original entry limit for dense refinement and zero-budget solves.
First try sparse primal scaling on the device. Build row and column lists from
accurate weights in bounded Float64 host blocks. Limit their combined storage
to the unused cost-cache budget and the size of one dense Float32 matrix.
Skip sparse refinement if the lists do not fit or leave an empty row or column.
Allow up to 10,000 sparse scaling iterations before the dense fallback. Sparse
iterations are much cheaper; a short limit can discard useful progress.
A zero cache budget disables both sparse and dense refinement.

The cutoff bounds the omitted mass before scaling. It does not certify the
scaled result. Store only corrected dual vectors and check the full, untruncated
plan again in Float64. If sparse refinement fails and a dense cost cache exists,
reuse that cache for dense primal scaling. Restore its cost values if this also
fails. No second full device matrix is needed. Dense refinement uploads whole
source columns; one column is the minimum. The persistent plan is never pruned.

A refinement attempt can improve the full-plan residual without meeting both
mass limits. In that case, retain its corrected dual as a warm start only if
the largest normalized mass residual falls by at least 10%. Reset the Anderson
history when this changes the device dual. Do not accept the partial plan or
add it to the transport history. Later iterations must pass the full checks.

Host log and weight buffers are reused across blocks. Device launches are
synchronized in batches. Periodic garbage collection releases completed native
command lists on oneAPI; their large driver allocations are not visible to
Julia's normal heap-pressure check.

The block size defaults to one million source–target pairs. If the target count
exceeds that size, one full source row is the minimum block. Saved plans contain
cached statistics and can be read after loading `experiment.jl`.

## Continue from a checkpoint

`continue_fit.jl` writes a new study and keeps the original baseline for the
mass and distortion checks. Set `CONTINUITY_START_STEP` to the next saved update
index when resuming within a run. The index starts at 1. In country-wise mode,
one pass contains one update per country, in target-count order. With a later
start index, `CONTINUITY_OUTER_STEPS` is the total pass limit, not the number of
additional passes. The default start index is 1 for a new continuation study.

Check that the seed checkpoint matches that index. Logs can be ahead of a
checkpoint, and plan and CSV writes are separate. This option does not repair
an interrupted write. Keep the parent logs and provenance with the new study;
the new metric file does not contain the skipped prefix. Planet publication
still requires the original input metadata and verification of the complete run.

Compact seeds retain the last pure proposal's dual vector. Use it as a warm
start after a restart. It is not an averaged dual for the damped mixture.

An explicit `initial_duals` vector can supply a better saved warm start to
`run_case`. Supply one finite target-dual vector per country, or `nothing`
for a cold start in that country. These vectors initialize the solver only;
they do not replace or validate a plan. The runner saves them in
`initial-duals.jls`. Keep their source and temperature in the study provenance.

The compact runner also writes `inner-stage.jls` after each validated inner
temperature stage. It keeps only the latest stage, with the update index,
country, temperature factor, plan, and dual. This is not an accepted outer
checkpoint. Before reusing its dual, check the index, prior, force, and
temperature against the intended solve. Never publish this proposal as a fitted
country. `compact_solve` exposes a `stage_callback` for other research runners.

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
