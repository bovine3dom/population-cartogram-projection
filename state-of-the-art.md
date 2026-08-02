# Similar Projects and State of the Art

_Web research reviewed 1 August 2026._

## Scope

This project does not generate a cartogram. It uses balanced entropic optimal
transport (Sinkhorn) to map geolocated source mass fractionally onto an existing
equal-population grid. Most cartogram software instead deforms polygons or
assigns each tile to one region, losing source-level contributions.

## Closest projects

| Project | Approach and relation to this project |
| --- | --- |
| [OWID Cartograms](https://github.com/owid/cartograms) | The closest upstream project and source of this target-grid style. It creates square or hex mosaics for arbitrary years using Dougenik-style polygon deformation and tessellation. It supports fixed and fluid scales, but only assigns cells at country level. |
| [World Population Cartogram](https://github.com/mattdzugan/World-Population-Cartogram) | A reusable, manually transcribed version of Max Roser's 2018 OWID map: about 15,000 squares representing 500,000 people each. It supplies several data formats but no coordinate projection or subnational mapping. |
| [popgrid](https://github.com/databites-tech/popgrid) | A 2026 Python package for population or land-area block cartograms from GeoDataFrames. It allocates regional quotas, deforms polygons, and rasterizes them; the result is region ownership rather than a soft source-to-cell lookup. |
| [cartogram-cpp / go-cart.io](https://github.com/mgastner/cartogram-cpp) | The current production implementation of the [fast flow-based algorithm](https://doi.org/10.1073/pnas.1712674115). It creates a continuous, contiguous all-coordinate projection from GeoJSON and target areas rather than filling a fixed mosaic. |
| [cartogramR](https://github.com/ESO-Rennes/cartogramR) and [cartogram](https://github.com/sjewo/cartogram) | `sf`-based R packages covering fast-flow, diffusion, Dougenik, non-contiguous, and Dorling cartograms. They output GIS geometry, not weighted lookup tables. |

## Optimal-transport implementations

- [OptimalTransport.jl](https://github.com/JuliaOptimalTransport/OptimalTransport.jl)
  is the nearest Julia numerical peer, with Sinkhorn variants and CUDA support.
  It lacks this project's geospatial preparation, sparsity selection, output
  schema, and vendor-neutral backends.
- [GeomLoss](https://www.kernel-operations.io/geomloss/) provides stabilized,
  epsilon-scaled Sinkhorn with linear-memory online and low-dimensional
  multiscale GPU backends. [POT](https://github.com/PythonOT/POT) exposes this
  lazy solver and many OT variants; [OTT-JAX](https://github.com/ott-jax/ott)
  adds accelerator-oriented scheduling, momentum, and low-rank methods.
- [FlashSinkhorn](https://github.com/ot-triton-lab/flash-sinkhorn), an ICML 2026
  project, is the clearest scaling reference. It streams squared-Euclidean costs
  through fused Triton kernels without materializing the source-by-target
  matrix. Memory is linear rather than quadratic, but it is limited to a
  PyTorch/Triton/CUDA stack and `p=2` cost.

## Adopting matrix-free Sinkhorn

### Current bottleneck

Let `S` be the source count, `T` the target-cell count, and `R` the retained
output-row count. The peak explicit dense cost state holds four `Float32` arrays:
the host cost, a temporary host transpose, and both backend orientations. It is
therefore approximately `16ST` bytes, excluding vectors and other temporaries.
The France factor-6 example (`S=48,416`, `T=15,768`) consequently reports
11.38 GiB before runtime overhead.

This storage is not mathematically necessary. Sinkhorn only needs reductions of
pairwise scores, never random access to the complete matrix. The current host
sparse reconstruction also works one source row at a time, so it needs `O(T)`
scratch per Julia thread rather than `O(ST)`. The returned table is a separate
lower bound: `cumulative_weight=1` can legitimately produce `R=ST`, so no
internal solver can guarantee linear end-to-end memory while the API
materializes that output.

### Exact online approach

[GeomLoss's online backend](https://www.kernel-operations.io/geomloss/api/pytorch-api.html#geomloss.SamplesLoss)
is the most directly transferable design. KeOps assigns output rows to workers,
streams tiles of the reduction points through shared memory, computes each cost
inside the tile, and immediately consumes it in a reduction. Its
[map-reduce documentation](https://www.kernel-operations.io/keops/engine/map_reduce_schemes.html)
is explicit that pair values are never materialized in global device memory.
This changes memory, not the optimization problem:

| Method | Working memory | Pairwise work per Sinkhorn stage |
| --- | ---: | ---: |
| Current dense solver | `O(ST)` | `O(ST)` per half-step after preparation |
| Exact online solver | `O(S+T)` | `O(ST)` per half-step, with costs recomputed |
| Block-sparse multiscale | `O(S+T+A)` | `O(A)`, where `A <= ST` is the active pair set |

An exact online version for this package would retain prepared source and target
coordinates, masses, and dual vectors instead of `cost`. One preliminary
matrix-free maximum reduction is still needed to preserve the current observed
maximum-distance normalization. Replacing that value with a bounding-box or
analytic bound would be cheaper, but would change the meaning of every eta.

Each source and target update can use a streaming log-sum-exp. Partial blocks
are represented by a maximum `m` and shifted exponential sum `s`. Two partials
combine stably as:

```text
m = max(m1, m2)
s = exp(m1 - m) * s1 + exp(m2 - m) * s2
```

The final log-sum-exp is `m + log(s)`. KeOps exposes this as its core
[`Max_SumShiftExp` reduction](https://www.kernel-operations.io/keops/api/math-operations.html#reductions),
and FlashSinkhorn performs the equivalent recurrence tile by tile. This can
evaluate each tile's costs once instead of the current separate full maximum and
exponential-sum passes.

For the default squared cost, prepared coordinates can express
`C_ij = c ||x_i-y_j||^2`. FlashSinkhorn additionally shifts the duals using the
per-point squared norms, turning each row score into a target bias plus
`2c x_i^T y_j`. Its [streaming formulation](https://arxiv.org/html/2602.03067v3#S3.SS1)
keeps a block of source rows and their log-sum-exp accumulators on chip while
streaming target blocks. This is valuable as an I/O pattern, but its Triton
matrix-multiply and tensor-core optimizations target higher-dimensional point
clouds. With only two coordinates and portable KernelAbstractions kernels,
direct squared-distance arithmetic may be simpler and as fast; both formulations
need benchmarking.

Solver defaults should not be copied. GeomLoss's legacy
[`SamplesLoss`](https://github.com/jeanfeydy/geomloss/blob/00e493f36bd6cc8471526e59afc07193a1926e47/src/geomloss/_legacy/samples_loss.py#L177-L208)
defaults to a debiased symmetric divergence, while its 2026
[`solve_sample`](https://github.com/jeanfeydy/geomloss/blob/00e493f36bd6cc8471526e59afc07193a1926e47/src/geomloss/ot/_implementations/sample.py#L188-L216)
API defaults to raw OT. FlashSinkhorn supports symmetric and alternating modes,
but [potential-change stopping](https://github.com/ot-triton-lab/flash-sinkhorn/blob/82a6d32f43f136c5db195b27be474c477a28f37f/API.md#L102-L120)
is optional. This package needs a raw balanced coupling, warmed alternating
updates, and its marginal-error test because candidate eligibility depends on
actual convergence.

### Kernel layout and portability

[KernelAbstractions 0.9.42](https://juliagpu.github.io/KernelAbstractions.jl/stable/api/)
provides workgroup-local memory, barriers, private state, and portable launches,
which are sufficient for the GeomLoss-style tiled reduction. Its portable kernel
language does not expose an equivalent of Triton's fused matrix-multiply or
tensor-core primitives. Those are not essential for a two-dimensional cost.

One layout may not suit both orientations. A GeomLoss-style group can let each
worker own one output row while all workers reuse a shared tile of opposite
coordinates. That works well when there are many output rows. For a highly
rectangular country problem, the shorter orientation may need multiple groups
per row and a second reduction over partial log-sum-exp values. FlashSinkhorn's
own rectangular benchmarks lose efficiency when too few row blocks are
available, so square A100 results should not be treated as a performance
forecast for these workloads. CPU workgroup sizes should also be selected
separately rather than inheriting the current fixed 256-lane GPU layout.

A hybrid policy is likely preferable: retain a dense path for small problems,
where one cost construction is amortized across many iterations, and select the
online path once `ST` exceeds a measured memory or runtime threshold. This
mirrors GeomLoss's tensorized/online split. The existing
[OptimalTransport.jl implementation](https://github.com/JuliaOptimalTransport/OptimalTransport.jl/blob/master/src/entropic/sinkhorn_stabilized.jl)
is not a drop-in matrix-free replacement: `SinkhornStabilized` consumes an
`S`-by-`T` cost matrix, allocates an equally sized Gibbs-kernel cache, and copies
that cache when returning the plan.

### Sparse output without a dense plan

At positive eta, every finite-cost coupling entry whose source and target masses
are strictly positive is positive; zero-mass rows or columns remain zero.
An all-pairs matrix-free solve is non-truncated and exact for its generated
costs, but backend operation order need not be bitwise identical to dense cost
construction. The package's sparse output remains post-processing. For source
`i`, the current source-normalized weights are:

```text
w_ij = softmax_j((beta_j - C_ij) / eta)
```

Only `beta`, coordinates, and eta are needed. Three extraction strategies are
compatible with a matrix-free solve:

| Strategy | Memory | Exactness and tradeoff |
| --- | ---: | --- |
| Recompute one full row on the host | `O(HT)` for `H` host threads | Preserves the current stable sort, cumulative threshold, and coordinate tie-break most closely; simplest first step. |
| Stream log-sum-exp plus top `K` | `O(SK)` | Exact when `maximum_cells=K` and ties use the same comparator. KeOps exposes `KMin_ArgKMin`, but its documented log-sum-exp is a separate reduction, so a direct implementation scans all pairs twice. |
| Adaptive top `K` | `O(sum_i K_i)`, worst-case `O(ST)` | Start small and double `K_i` only for unresolved rows. This is exact eventually, but each round rescans all `T` targets for those rows and no expected bound follows without a distributional assumption. |

The selected entries must retain their full-row softmax values and must not be
renormalized. Existing host code can still aggregate original source values by
target to produce deterministic `weight_mean`. Candidate-eta statistics require
the same extraction logic, so moving only the Sinkhorn iterations to the backend
does not remove their `O(ST)` scans or sorting cost.

GeomLoss's 2026 API similarly distinguishes a lazy plan/operator from a dense
`plan`; it has no public sparse-plan accessor. FlashSinkhorn provides streaming
plan-vector application but no top-k plan output. A portable top-k extractor
would therefore be project-specific rather than a direct library port.

### Multiscale as a later step

GeomLoss's multiscale backend clusters low-dimensional points, solves first on
weighted centroids, sorts fine points by cluster, and visits only cluster-pair
blocks selected from coarse dual scores. Its
[block-sparse reductions](https://www.kernel-operations.io/keops/python/sparsity.html)
can reduce arithmetic when low eta makes transport local, which is promising for
this two-dimensional problem. The worst case remains `A=ST`, especially at high
eta when the kernel is broad.

The practical GeomLoss scheme is a two-scale heuristic and finite truncation is
approximate. Schmitzer's
[stabilized sparse scaling algorithm](https://arxiv.org/abs/1610.06519), which
combines log stabilization, epsilon scaling, dual-aware kernel truncation, and
coarse-to-fine refinement, provides computable truncation-error controls.
The paper nevertheless notes that truncated stabilized iteration need not
converge generally and treats epsilon scaling as a heuristic. Porting it would
require clustering, reordering, bidirectional block ranges, support validation,
and new error reporting, so it should follow an exact online baseline.

FFT/convolutional methods are a poor immediate fit because sources are irregular
H3 or regional centroids and cartogram cells form a masked rather than complete
grid. Nyström, NFFT, and low-rank methods are also approximate, become harder at
small eta, and do not directly solve sparse-plan extraction. The available
[Julia NFFT-Sinkhorn prototype](https://github.com/rajmadan96/NFFT-Sinkhorn-Wasserstein_distance)
is an unmaintained research prototype. Maintained Julia NUFFT packages include
[NFFT.jl](https://juliamath.github.io/NFFT.jl/dev/),
[NonuniformFFTs.jl](https://jipolanco.github.io/NonuniformFFTs.jl/stable/), and
[FINUFFT.jl](https://finufft.readthedocs.io/en/v2.4.0/julia.html), but none
provides an end-to-end Sinkhorn backend or sparse-plan extractor.

### Research recommendation

The lowest-risk direction is to adopt the **GeomLoss online abstraction with
FlashSinkhorn's fused streaming reduction**, not either library's public API:

1. Preserve the dense implementation as a numerical oracle and small-problem
   path.
2. Study an all-pairs matrix-free `cost_power=2` path that preserves the current
   maximum-distance scale, alternating eta continuation, and marginal checks.
3. Initially reconstruct sparse rows on the host from coordinates and `beta`;
   evaluate bounded or adaptive backend top-k only if profiling identifies this
   stage as dominant.
4. Benchmark alternate row-owning and split-row kernels on CPU, CUDA, ROCm,
   Metal, and oneAPI rather than assuming one 256-item layout.
5. Consider dual-aware multiscale truncation only after the exact online solver
   establishes numerical and performance baselines.

As of 2 August 2026, those prerequisites are met. The experimental
`cost_mode=:truncated` path uses Morton-ordered 256-point coarse blocks over
32-point leaves, current per-block dual maxima, a real pair as a row witness,
and a conservative omitted-mass budget. Eta-boundary updates and marginal audits
remain exact all-pairs operations. It is opt-in because dynamic truncation does
not inherit a general convergence proof and because broad kernels above roughly
eta `1e-3` did not amortize block traversal for France factor 3 on the tested
oneAPI backend; smaller workloads crossed over later or not at all.

The decisive validation risk is floating point rather than OT theory. Dense
costs use host `Float64` distance arithmetic, round to `Float32`, normalize, and
then apply the power. Matrix-free squared costs instead use high/low `Float32`
coordinates and normalize regenerated squared distances. This changes operation
order, and the default eta list reaches `1e-7`, far below the `0.01` low-eta case
evaluated in the FlashSinkhorn paper. Benchmarks should record cost parity,
convergence checkpoint, selected eta, retained rows and mass, keyed weights, and
peak host/backend memory for synthetic fixtures and France factors 1, 3, and 6.

## Assessment

No reviewed open-source project combines a fixed OWID-style mosaic,
fine-grained IDs, source- and cell-relative fractional weights, automatic
regularization, sparse extraction, and portable CPU/GPU execution. The closest
conceptual pipeline is **OWID Cartograms plus a matrix-free point-cloud OT solver**.

The main gap is computational. GeomLoss and FlashSinkhorn show that the default
squared-distance solve can be made linear-memory without changing the balanced
entropic objective, while Schmitzer's truncation and error-control framework is
the stronger reference if quadratic arithmetic later becomes limiting.
`cartogram-cpp` remains stronger for continuous geometry and topology; this
project's distinctive output is a transport-derived attribution table for an
already designed cartogram.

An emerging research direction is the 2025
[Learning-based density-equalizing map](https://doi.org/10.3934/math.20251140),
which reports improved density equalization and bijectivity from a coarse-to-fine
neural model. It produces continuous deformation, not a discrete coupling.
