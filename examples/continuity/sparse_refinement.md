# Fixed-graph refinement pilot

Load `experiment.jl` before `sparse_refinement.jl`. The latter defines
`SparseRefinement`. This is research code. The planet publisher does not use it.

`graph(n, m, source, target, cost; maxedges=20_000_000)` builds row and column
indexes. Each edge must be unique. Each source and target must have an edge.
The edge limit is a count limit, not a process-memory limit. The function rejects
indexes that do not fit in Int32. A nonempty graph need not have a feasible
transport plan.

`solve(graph, a, b, backend; eta)` uses KernelAbstractions log-domain reductions.
Use `oneAPI.oneAPIBackend()` for the Intel GPU. The source and target masses
must be positive and sum to one. `initial_beta` can supply a previous target
dual. The default target checks are L1 error at most `1e-6` and maximum relative
error at most `1e-4`. Source relative error must be at most `1e-10`.

The solver checks Float64 host weights before it returns. It can use GPU primal
scaling to correct Float32 error. Failure to meet the limits raises an error.
The returned weights refer to the sorted edges in the graph, not input order.

The graph is part of the model: omitted edges have zero weight. These mass
checks do not prove agreement with an all-pair solve. They do not prove good
border alignment, low blur, or a mobile memory budget. Check these properties
on real data before publication. No new border penalty is in this solver.

Run the small dense-reference and failure checks with:

```sh
julia --project=examples/uk-h3 test/sparse_refinement.jl
CONTINUITY_GPU_TEST=1 julia --project=examples/uk-h3 test/sparse_refinement.jl
```
