# Higher factors preserve the factor-1 transport

## Scope

Investigated on 2026-10-15 without running a solver. No fitting code, H3-MON
code, metadata, or published dataset was changed. The audit reads saved
country parts, manifests, cell reports, and publication hashes.

## Finding

The user's observation is correct. The published native H3-6 factors 2, 3,
and 5 are constrained subdivisions of the same factor-1 mapping. They are not
independent fine-grid transport and continuity fits. This is a change in the
fitting method, not a renderer or Arrow encoding fault.

The native H3-6 source populations are real. The factor-1 source fit uses KA
and oneAPI, guided by the old H3-5 flows. The higher target factors then use
separate CPU linear programs within each coarse target. Those programs solve
a different problem from the earlier fine-grid transport solver.

## Where the method changed

Commit `49c352a` (2026-10-14 23:09 UTC) added the native-source hierarchy.
Commit `e0be40f` (2026-10-14 23:58 UTC) added `target_subdivision.jl` and
`subdivide_native.jl`. The latter commit introduced the higher-factor path
used by these publications. Later retries improved convergence but kept the
same constraints.

`subdivide_native.jl` reads completed factor-1 parts. It calls
`TargetSubdivision.subdivide`, not the fine-grid continuity fitting loop.
All three published `fit-input.toml` files name
`output/planet-h3-6-native-factor1-v2` as their coarse input.

In `target_subdivision.jl`:

- Each old target is handled independently in `subdivide`.
- `ids=source[es]` and `mass=weights[es]` admit only its existing contributors.
- The source equations in `split_cell` fix each old contribution in total.
- Fine XYZ and density means follow a local linear field from coarse means.
- A single amplitude between zero and one controls that field per coarse cell.
- `cost[end]=-1` maximizes this amplitude. There is no fine-grid OT distance,
  entropy term, eta search, or cross-cell continuity objective in this LP.

Thus, for every source `i` and old target `j`, the final plan must satisfy:

```text
sum(P_fine[i, child] for child in children(j)) = P_factor1[i, j]
```

A fine solve cannot change how much that source sends to another coarse cell.
The coarse allocation is a hard constraint, not a warm start. More target
cells do not remove that constraint. Eta tuning cannot release it.

## Read-only measurements

The audit checks all 206 countries and all 6,187,416 coarse contributions for
each higher factor. It verifies the fitted-part hashes against the active
publication audits and verifies the actual published transport hashes.

| Factor | Maximum absolute coarse-edge error after collapse | New source-to-coarse edges | Median guide amplitude | Uniform fallback cells |
| --- | ---: | ---: | ---: | ---: |
| 2 | 5.55e-17 | 0 | 0.272 | 0 |
| 3 | 2.22e-16 | 0 | 0.227 | 4 |
| 5 | 3.33e-16 | 0 | 0.198 | 4 |

Every fine target coordinate is also an exact subdivision of its coarse cell.
Collapsing each fine block recovers the factor-1 source allocations to floating
point precision. These are normalized country joint weights, not people.

The guide amplitudes show that the allowed local field is often reduced well
below its proposed coarse-gradient variation. They are not direct measures of
spatial resolution. The four fallback cells do not explain the overall effect:
factor 2 has no fallback and has the same fixed-coarse-allocation constraint.

The reproducible read-only script and complete report are retained at:

- `output/continuity-factor-investigation/audit_saved.jl`
- `output/continuity-factor-investigation/report.toml`
- `output/continuity-factor-investigation/audit-saved.log`

The script imports serialization, hashes, tables, and statistics only. It does
not import or call a solver. Input hashes are checked before and after reading.

## Difference from the older implementation

In `examples/uk_h3.jl`, including commit `6fb2ebd`, `load_cartogram(...; factor)`
creates the fine target grid before `distribute` fits the mapping. The solver
receives the fine targets, not fixed source-to-parent allocations.

The earlier continuity refinement path, introduced in `9af6e5e`, also fits
on the fine grid. `refine_grid.jl` creates fine countries, solves fine-grid
baselines and seeds, and calls `run_case` with the fine target graph. Coarse
interpolation supplies a starting field. It does not fix the final coarse
contributions.

Both old and new code subdivide the artwork geometry. A subdivided country
outline alone is therefore expected. The regression is in the transport and
projected field, which the new path ties to the coarse solution.

## Why this happened and why existing checks missed it

The H3-6 work log records failed direct refinement trials with excess folds or
broad support. The constrained subdivision was introduced to preserve the
coarse geometry within the time budget. It was then published as a set of
higher-factor choices. That substitution does not meet the earlier meaning
of fitting at the requested factor.

Mass conservation, source coverage, sharp support, and small coarse-geometry
changes all passed. Those checks did not test whether the finer solver could
change coarse allocations. Preserving the coarse solution was built into the
method, so these checks could not establish independent fine-scale detail.
Removing export row reduction and replacement dictionaries does not undo a
constraint applied upstream during fitting.

## Required correction, not performed here

Restore a transport and continuity optimization on the requested fine grid.
Use the coarse solution only to initialize that optimization. Tune eta and
scale the penalties for the fine problem. Do not fix each source-to-parent
contribution or impose the coarse interpolated moments as the final answer.

Before another planet run, add a small regression case whose fine optimum
needs a different coarse allocation. Check that the solver can make that
change. Describe the existing higher-factor datasets as constrained
subdivisions until genuine fine-grid results replace them.
