# Repository reuse TODO

## Agreed Direction

The primary product is a small, reusable population-to-cartogram mapper. Most
users will supply a table of weighted geographic centres, such as NUTS2 regions,
IRIS areas, UK output areas, or another regional geography:

```text
id, population, x, y, country_code
```

The package will match those sources to the small OWID cartogram grid. It will
not require users to download the Kontur H3 dataset, install ClickHouse, or have
a supported GPU for modest regional problems.

The owner's large H3 workflow remains supported as an advanced path. H3 rows
will be converted to the same five-column source model before entering the
shared cartogram and solver code. The roughly 1 GB source datasets remain
external and are not bundled with the package.

The numerical implementation supports only dense, balanced, Float32 log-domain
Sinkhorn with epsilon continuation. A direct CUDA baseline and a single
KernelAbstractions implementation for CUDA, oneAPI, and CPU are temporarily
retained for comparison. There is no separately maintained CPU solver.

This supersedes the earlier artifact-first plan. A fixed H3-derived mapping may
still be published as an optional release asset, but the main product computes
a custom mapping from the user's own source table.

## Current Status

The repository now has a root Julia package and a one-country accelerator workflow for
the five-column source contract. The KernelAbstractions path runs end to end on
the Intel UHD 620 through oneAPI, including dimensions larger than one
workgroup. Direct CUDA and KernelAbstractions CUDA still require comparison on
NVIDIA hardware. The advanced workspace still contains duplicate experimental
solvers that have not yet been migrated.

## 1. Define The Public Data Contract

### Source input

The canonical input columns are:

```text
id
population
x
y
country_code
```

- [x] Treat `id` as an opaque identifier and preserve its input type. It can be
      an H3 index, IRIS code, ONS code, NUTS code, integer, or string.
- [x] Define `(country_code, id)` as the source key unless global uniqueness is
      explicitly required.
- [x] Do not require a separate `region_id`. Add a grouping identifier only if a
      concrete future feature needs multiple support points for one logical
      source.
- [x] Require finite, positive `population` values. The package rejects zero
      population rather than silently discarding rows.
- [x] Require finite source-centre coordinates.
- [ ] Define the accepted `x` and `y` coordinate convention. The likely default
      is WGS84 longitude and latitude, but the current code also reverses the
      vertical axis for rendering and must not leak that into the input contract.
- [ ] Permit column-name keywords if users should not have to rename an existing
      table to the canonical names.
- [x] Validate every country has at least one positive-population source and a
      matching OWID target.

### Target grid

The checked-in `data/cartogram.csv` is approximately 660 KB and contains 54,978
OWID grid cells. It is small enough to distribute with the package, subject to
confirming its license and provenance.

- [x] Give every OWID cell a stable `cell_id` that does not depend on DataFrame
      row order.
- [x] Define the target table as `cell_id`, `grid_x`, `grid_y`, and
      `country_code`.
- [ ] Verify and document that each original OWID cell represents equal target
      population mass.
- [x] Load the checked-in CSV directly or automate creation of any packaged
      Arrow derivative. Do not require the unexplained current `cartogram.arrow`.
- [ ] Preserve a parent cell identifier when the target grid is subdivided.
- [ ] Make subdivision an explicit quality/performance option rather than an
      implicit factor of six.

### Mapping output

The essential normalized mapping is:

```text
id
country_code
cell_id
source_share
```

`source_share` is the fraction of the input source's population assigned to the
target cell. Shares for each `(country_code, id)` should sum to approximately
one, with any loss from sparse extraction reported explicitly.

The following convenient columns are derivable and may be included in a
denormalized output:

```text
grid_x
grid_y
transport_mass
```

`grid_x` and `grid_y` come from the target grid. `transport_mass` is
`source_share * population`.

- [x] Return the normalized mapping by default; keep convenient denormalized
      columns out of the core result.
- [ ] Document the distinction between `source_share` and `transport_mass`.
- [ ] Report retained and dropped source share after sparsification.
- [x] Keep the fractional mapping as the canonical result.
- [ ] Provide a derived dominant-source assignment for users who want exactly
      one source identifier per cartogram cell.
- [ ] Define separate projection helpers for extensive quantities and
      population-weighted intensive quantities.

### Definition of done

A newcomer with a supported CUDA or oneAPI device can provide a five-column
regional table and receive a documented source-to-OWID-cell mapping without
downloading large population or boundary datasets.

## 2. Build The Simple GPU Vertical Slice

- [x] Add a small checked-in fixture resembling NUTS2 input.
- [x] Use the bundled OWID grid at native resolution for the first example.
- [ ] Solve each country independently.
- [ ] Add one command that validates the fixture, fits the mapping, writes it,
      projects a sample value, and optionally renders the result.
- [x] Assert input schemas before constructing a dense cost matrix.
- [x] Assert source and target mass totals before solving.
- [x] Assert convergence, mass conservation, finite output, and expected output
      columns after solving.
- [x] Assert dense source shares sum to the documented tolerance.
- [ ] Assert retained share and mass loss once sparse extraction is implemented.
- [ ] Report included, remapped, skipped, and failed countries.
- [ ] Fail on an incomplete result unless the caller explicitly permits partial
      output.
- [x] Keep this example independent of H3, Kontur, Natural Earth, GeoNames,
      ClickHouse, DuckDB, and GDAL. CUDA hardware remains required for fitting.

### Candidate public workflow

```julia
grid = load_owid_grid()
mapping = fit_mapping(sources, grid)
cells = project_to_grid(mapping, sources; value=:some_value)
render_cartogram(cells; value=:some_value)
```

These names are provisional. The important separation is that fitting a mapping
depends on identifiers, population, and centres, while projecting values and
rendering can be repeated without solving again.

## 3. Make The Spatial Model Explicit

The spatial transform is currently a larger reuse risk than the Sinkhorn
algorithm. `prepare_sinkhorn2_problem` independently stretches the extrema of
the supplied source centres to each target country's cartogram bounding box at
`make-lookup-table/cuRegOT.jl:1215-1228`.

That means one outlier, or adding/removing a source, can change every source
distance. Countries with only one or two sources also have poorly determined
scaling.

- [ ] Extract coordinate transformation and cost construction into an explicit,
      named model rather than embedding it in solver preparation.
- [ ] Decide whether the initial model uses input extrema, stable country
      bounds, robust quantiles, or another fixed transform.
- [ ] Record transform parameters and cost normalization in mapping metadata.
- [ ] Keep geographic source coordinates separate from cartogram screen
      coordinates and rendering orientation.
- [ ] Document that a single centre approximates a region and does not preserve
      its boundary, shape, adjacency, or internal population distribution.
- [ ] Recommend population-weighted centres where available.
- [ ] Test one-source and two-source countries, coincident centres, outliers,
      islands, overseas territories, and disconnected countries.
- [ ] Test that row order and unrelated table columns cannot change a mapping.
- [ ] Verify that uniform target mass is correct for original and subdivided
      OWID cells.

Multiple weighted support points can later improve the representation of a
large or disconnected region. Do not add a separate grouping column until this
is implemented and its semantics are clear.

## 4. Create A Proper Julia Package Boundary

The first refactor should preserve behavior while separating importable,
side-effect-free functions from data loading and orchestration.

- [x] Put `Project.toml` at the repository root if this repository will be the
      Julia package.
- [x] Add `name`, `uuid`, `version`, `[compat]`, and test targets.
- [x] Create a `PopulationCartogramProjection` module or choose a final package
      name.
- [ ] Remove include-time data loading from `make-lookup-table/lib.jl:9` and
      `make-lookup-table/lib.jl:246-259`.
- [x] Importing the module must not read files, start GPU work, or write output.
- [ ] Move full-data orchestration into scripts with `main(args)`.
- [ ] Replace current-working-directory-relative paths with `@__DIR__`-relative
      or explicit input/output paths.
- [ ] Remove the unconditional Germany scratch run from the supported script.
- [ ] Keep exploratory scripts out of the supported import path.
- [ ] Move or rename `make-lookup-table/wtf.jl` if it remains useful.
- [ ] Remove the renderer's dependency on the global `country_colours` value.
- [ ] Separate generated output from source under an ignored output directory.

### Possible target layout

```text
Project.toml
Manifest.toml
src/
  PopulationCartogramProjection.jl
  sources.jl
  grid.jl
  costs.jl
  mapping.jl
  projection.jl
  sinkhorn.jl
  rendering.jl
scripts/
  build_h3_mapping.jl
test/
  runtests.jl
  fixtures/
examples/
  regional_centres.jl
data/
  cartogram.csv
  country-code.csv
  README.md
```

Keep one CUDA Sinkhorn implementation in the package. Host-side validation,
table preparation, and result extraction are not alternative solver paths.

## 5. Keep One Log-Domain Sinkhorn Solver

### Supported numerical scope

The supported algorithm is dense, balanced, Float32 log-domain Sinkhorn with
epsilon continuation. Direct CUDA is the performance baseline while the single
KernelAbstractions implementation is evaluated on CUDA, oneAPI, and CPU.

- [x] Define explicit direct-CUDA and KernelAbstractions comparison entry points.
- [x] Share validation, schedules, convergence checks, result construction, and
      mapping extraction between comparison implementations.
- [ ] Share progress reporting, stage observation, and sparse extraction.
- [x] Implement CUDA block-reduction row and column updates and CUDA marginal
      evaluation in the package.
- [x] Preserve the optimized block-per-marginal structure from
      `make-lookup-table/cuRegOT.jl:127-250`.
- [x] Implement portable KernelAbstractions row, column, and marginal kernels.
- [x] Run the portable kernels through oneAPI on Intel UHD 620.
- [x] Run the same portable kernels through the KernelAbstractions CPU backend.
- [ ] Compare portable and direct CUDA performance on representative NVIDIA
      hardware before selecting the retained implementation.
- [ ] Consolidate the two active optimized continuation loops around
      `make-lookup-table/cuRegOT.jl:667-1004`.
- [x] Update every target potential and normalize the final dual gauge without
      changing the reconstructed plan.
- [x] Avoid materializing the dense transport plan during solving.
- [x] Return a result containing duals, final epsilon, marginal error, iteration
      counts, convergence status, and stopping reason.
- [x] Validate matrix dimensions, finite costs, strictly positive marginals,
      equal total mass, positive epsilon values, non-empty schedules, and
      positive iteration/check intervals.
- [ ] Document the dense memory cost. CUDA stores both the cost matrix and its
      transpose.

### Accelerator setup and selection

Keep CUDA, KernelAbstractions, and oneAPI as direct dependencies during the
comparison. Solving must check the requested accelerator and fail clearly.

- [x] Declare CUDA in `Project.toml` and record a compatible version range.
- [x] Declare KernelAbstractions and oneAPI with compatible version ranges.
- [x] Check `CUDA.functional()` before preparing or allocating a mapping problem.
- [x] Report a clear unavailable-device error on machines without NVIDIA CUDA.
- [x] Support explicit `:cuda`, `:ka_cuda`, `:ka_oneapi`, and `:ka_cpu` choices.
- [x] Do not silently change accelerator backends.
- [x] Document Intel Gen9 legacy-runtime installation and driver discovery.
- [ ] Benchmark small and large CUDA problems on representative hardware.

### Remove unsupported solver families

Create regression tests first, then remove:

- [ ] The experimental quasi-Newton `curegot_solver` and sparse-Hessian code.
- [ ] The one-thread-per-row CUDA kernels superseded by the block kernels.
- [ ] The older single-epsilon and schedule Sinkhorn front ends.
- [ ] The repeated-schedule and repeated-preparation reference front ends after
      they have served as migration oracles.
- [ ] `match_h3_to_cartogram_stable` and other obsolete wrappers.
- [ ] The JuMP/HiGHS optimal-transport implementation.
- [ ] JuMP, HiGHS, SparseArrays, and other dependencies left unused by the
      supported code.
- [ ] GPU-specific names such as `sinkhorn2` once callers use the canonical API.

### Eta selection and sparse extraction

- [ ] Keep row-count-based eta selection in the cartogram layer, not the generic
      numerical solver.
- [ ] Give ordinary users a documented regularization/sparsity preset rather
      than exposing every experimental parameter immediately.
- [ ] Replace callbacks exposing raw GPU arrays with a backend-neutral stage
      observation interface.
- [ ] Make CUDA row counting and final host extraction follow exactly the same
      cumulative-share, minimum-weight, tie, and neighbor-limit rules.
- [ ] Fix the current mismatch where CUDA row counting does not apply
      `min_weight` but final host extraction does.
- [ ] Report dense solver marginal error separately from mass dropped during
      sparse extraction.

## 6. Add Tests And Continuous Integration

### Host-side tests

- [x] Test source-table validation, OWID loading, package loading, and clear
      unavailable-accelerator errors.
- [x] Test solver input validation independently of CUDA availability.
- [ ] Test country partitioning, country-code reconciliation, and failure
      reporting.
- [ ] Test cartogram subdivision without mutating its input.
- [x] Add a deterministic regional-centres fixture.

### CUDA numerical tests

- [x] Define CUDA-gated 1x1, rectangular, continuation, and regional mapping
      tests.
- [x] Compile all four KernelAbstractions CUDA kernels to PTX and cubin for
      `sm_80`.
- [ ] Run the CUDA-gated tests on NVIDIA hardware.
- [ ] Add symmetric and asymmetric 2x2 transport problems.
- [x] Add a 257x257 problem to exercise multi-block reductions.
- [ ] Add an imbalanced problem with more than eight sources to exercise atomic
      marginal accumulation.
- [ ] Test convergence, explicit non-convergence, and stopping reasons on CUDA.
- [ ] Test source-share normalization and population-weighted target marginals
      on CUDA.
- [ ] Test sparse mass-loss reporting once sparse extraction exists.
- [x] Keep performance benchmarks separate from unit tests.

### oneAPI numerical tests

- [x] Run 1x1, rectangular, 257x257, continuation, and regional mapping tests on
      Intel UHD 620.
- [x] Test population-weighted target marginals on oneAPI.
- [x] Record the required Intel Gen9 legacy-driver environment variable.

### CPU numerical tests

- [x] Run 1x1, closed-form 2x2, rectangular, 257x257, continuation, and regional
      mapping tests through the same KernelAbstractions kernels.
- [x] Test population-weighted target marginals on CPU.
- [x] Add opt-in CPU timing and allocation reporting to the backend benchmark.
- [ ] Evaluate whether CPU allocation overhead is acceptable beyond modest
      regional problems.

### CI

- [ ] Add non-GPU CI that instantiates the project and runs host-side tests.
- [x] Test the documented error when CUDA is unavailable.
- [ ] Add NVIDIA GPU CI for the numerical and end-to-end tests.
- [ ] Add oneAPI CI if a suitable Intel runner becomes available.

## 7. Retain H3 As An Advanced Input Path

H3 should enter before the shared five-column source contract:

```text
external H3 population rows
  -> validate H3 indexes and resolution
  -> optionally aggregate to parent cells
  -> assign countries
  -> calculate centre x/y
  -> id, population, x, y, country_code
  -> shared CUDA mapping pipeline
```

- [ ] Preserve the H3 index in the generic `id` column.
- [ ] Preserve the H3 identifier type where Arrow and downstream joins allow it.
- [ ] Make parent-resolution aggregation explicit and report its population
      totals.
- [ ] Separate country assignment from generic mapping preparation.
- [ ] Report unmatched and ambiguous population during boundary assignment
      instead of silently dropping it at `make-lookup-table/lib.jl:250-251`.
- [ ] Process countries independently and release large cost matrices promptly.
- [ ] Keep advanced subdivision, eta tuning, profiling, and CUDA controls
      available to the owner's large workflow.
- [ ] Add a tiny H3 fixture that exercises the adapter without bundling Kontur or
      Natural Earth data.
- [ ] Keep the full H3 build as a supported script or advanced API, not as
      import-time package behavior.

### External H3 data preparation

- [ ] Pin the exact Kontur release, download URL, checksum, schema, H3
      resolution, license, and attribution.
- [ ] Pin ClickHouse and remove the environment-specific `chungus/...` path from
      `make-lookup-table/population-data/wrangler.sql`.
- [ ] Pin the Natural Earth release, archive checksum, license, and boundary
      conversion commands.
- [ ] Pin or package the required `geojson2h3.jl` tool.
- [ ] Decide and document the boundary H3 resolution.
- [ ] Make generated filenames match those consumed by the Julia workflow.
- [ ] Replace instructions to "probably" change compression with tested,
      deterministic commands.
- [ ] Keep these large inputs outside the source repository.

## 8. Data, Licensing, And Citation

### OWID grid and country codes

- [ ] Record the exact OWID source revision or export date, settings, expected
      dimensions, and checksum.
- [ ] Confirm redistribution rights for bundling `data/cartogram.csv`.
- [ ] Document the grid schema and its numeric country-code system.
- [ ] Document the provenance and license of `data/country-code.csv`.
- [ ] Replace the one-off France remapping at
      `make-lookup-table/make-lookup-table.jl:42` with a documented crosswalk.
- [ ] Replace the copied Europe country-name list with explicit requested scope
      or a maintained regional classification.

### Optional city labels

- [ ] Keep GeoNames labels optional and out of the core fitting workflow.
- [ ] Record the GeoNames license, attribution, source snapshot, and checksum.
- [ ] Pin DuckDB and `zipfs` if the current preparation method remains.
- [ ] Decide what population threshold the canonical city fixture uses.

### Project licensing

- [ ] State that the root BSD 2-Clause license covers original source code.
- [ ] Clarify what `data/LICENSE` covers; it does not automatically cover
      Kontur, Natural Earth, GeoNames, or all derived outputs.
- [ ] Add a third-party data and software notices document.
- [ ] Decide and document the licensing status of generated mappings and images.
- [ ] Add complete citations for OWID, Kontur, Natural Earth, GeoNames, H3, and
      the optimal-transport method where they apply.
- [ ] Add `CITATION.cff` after project title, authorship, and version are settled.

## 9. Reproducibility And Reliability

- [ ] Record backend, thread count, Julia version, manifest hash, solver options,
      coordinate transform, source checksum, grid checksum, and git commit with
      generated mappings.
- [ ] Record CUDA/driver and GPU details with every generated mapping.
- [ ] Define whether reproducibility means byte identity or numerical agreement
      within documented tolerances.
- [ ] Replace unseeded random country colours with deterministic output.
- [ ] Handle the case where every country fails before concatenating results.
- [ ] Remove or resolve comments describing possible corruption, mutation, and
      segmentation faults from the supported path.
- [ ] Quantify all population excluded during cleaning, country reconciliation,
      H3 boundary assignment, solving, and sparse extraction.

## 10. Documentation And Repository Hygiene

- [x] Replace the "under construction" README with the simple regional-centres
      workflow and clearly label advanced H3 functionality.
- [x] Explain the five-column input and normalized mapping output first.
- [x] Document direct CUDA and KernelAbstractions CUDA/oneAPI/CPU paths.
- [x] State clearly that CPU uses the same kernels rather than a separate solver.
- [x] Document Intel Gen9 system package and Level Zero driver discovery.
- [x] Document the reproducible CUDA comparison benchmark.
- [x] Document the centre-point approximation and spatial transform limitations.
- [ ] Add an advanced prerequisites section for H3 data preparation rather than
      presenting ClickHouse, DuckDB, GDAL, and 7-Zip as ordinary requirements.
- [ ] Add root ignore rules for generated outputs, logs, profiles, editor files,
      and coverage files.
- [ ] Decide whether the existing untracked `out.arrow` is useful before moving,
      deleting, or ignoring it.
- [ ] Classify existing Arrow and PNG files as examples, release artifacts, or
      scratch output.
- [ ] Remove or rename ambiguous output names such as `hello.png`.
- [ ] Add contribution guidance after setup and test commands are stable.
- [ ] Add tagged releases and release notes once the first public contract is
      usable.

## Deferred: Separate Solver Package

Do not split the solver into another repository now. Keep direct CUDA and the
portable implementation only until the CUDA comparison identifies which one to
retain; the low-maintenance CPU backend remains part of the portable path.

Reconsider extraction only if:

- [ ] The internal numerical interface is stable and fully tested.
- [ ] The solver module has no H3, DataFrames, rendering, or cartogram-specific
      dependencies.
- [ ] A second concrete project needs the solver independently.
- [ ] Maintaining a separate release and compatibility contract would reduce
      rather than add work.

## Suggested Pull Request Sequence

1. **State the contract:** document the five-column source input, OWID target
   grid, normalized mapping output, and centre-point approximation.
2. **Extract the accelerator solver:** move the optimized log-domain kernels
   behind the package API and keep CPU support inside the portable kernel path.
3. **Compare GPU implementations:** run direct CUDA and KernelAbstractions CUDA
   numerical tests and benchmarks on representative NVIDIA hardware, then
   delete the losing implementation.
4. **Deliver the simple example:** run a NUTS2-like fixture against the bundled
   OWID grid and project a sample value.
5. **Create the package boundary:** remove import-time I/O and globals, move
   orchestration to scripts, and separate mapping from rendering.
6. **Remove old solvers:** delete quasi-Newton, JuMP/HiGHS, and duplicate
   Sinkhorn paths after regression coverage exists.
7. **Adapt H3:** convert the existing large workflow to the shared source schema
   and retain CUDA tuning as advanced functionality.
8. **Finish reuse readiness:** settle data provenance and licensing, improve
   documentation, and publish a tagged release.

Broad formatting, history cleanup, community templates, and aesthetic renaming
should follow a verified GPU vertical slice rather than precede it.
