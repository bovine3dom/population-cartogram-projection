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
Sinkhorn with epsilon continuation. One KernelAbstractions implementation runs
on CUDA, AMDGPU, oneAPI, and CPU; the direct CUDA baseline was removed after the
CUDA comparison. There is no separately maintained CPU solver.

This supersedes the earlier artifact-first plan. A fixed H3-derived mapping may
still be published as an optional release asset, but the main product computes
a custom mapping from the user's own source table.

## Current Status

The repository now has a root Julia package and a one-country accelerator workflow for
the five-column source contract. The same KernelAbstractions path runs end to
end on Intel UHD 620 through oneAPI and NVIDIA GTX 1080 Ti through CUDA,
including dimensions larger than one workgroup. Direct CUDA comparison showed
1-10% overhead on representative rectangular problems and a 5% speedup at
4096x4096, so the portable implementation was retained. The advanced workspace
still contains duplicate experimental solvers that have not yet been migrated.
The AMDGPU backend is wired through the same kernels and awaits ROCm hardware
validation.
Automatic eta tuning and deterministic sparse extraction now run through the
portable solver. A cached 8,346-source real UK resolution-6 H3 check matches
scratch preparation to Float32 precision and agrees on 96.15% of dominant
target cells.

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
- [x] Define `x` and `y` as WGS84 longitude and latitude in degrees, validate
      their ranges, and reverse only the internal cartogram vertical transform.
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
- [x] Report retained and dropped share per source and population-weighted mass
      after sparsification.
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
- [x] Assert retained share and mass loss after sparse extraction.
- [ ] Report included, remapped, skipped, and failed countries.
- [ ] Fail on an incomplete result unless the caller explicitly permits partial
      output.
- [x] Keep this example independent of H3, Kontur, Natural Earth, GeoNames,
      ClickHouse, DuckDB, and GDAL. Accelerator selection remains explicit.

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
epsilon continuation through one KernelAbstractions implementation on CUDA,
oneAPI, and CPU.

- [x] Define explicit direct-CUDA and KernelAbstractions comparison entry points
      for the completed CUDA evaluation.
- [x] Share validation, schedules, convergence checks, result construction, and
      mapping extraction between comparison implementations.
- [ ] Share progress reporting.
- [x] Use backend-neutral stage observation and deterministic sparse extraction
      for automatic eta tuning.
- [x] Implement and benchmark direct CUDA block reductions as the temporary
      comparison baseline.
- [x] Preserve the block-per-marginal reduction structure in the retained
      portable kernels.
- [x] Implement portable KernelAbstractions row, column, and marginal kernels.
- [x] Run the portable kernels through oneAPI on Intel UHD 620.
- [x] Run the same portable kernels through the KernelAbstractions CPU backend.
- [x] Compare portable and direct CUDA performance on representative NVIDIA
      hardware before selecting the retained implementation.
- [x] Consolidate the package around the portable continuation loop after the
      CUDA comparison.
- [x] Update every target potential and normalize the final dual gauge without
      changing the reconstructed plan.
- [x] Avoid materializing the dense transport plan during solving.
- [x] Return a result containing duals, final epsilon, marginal error, iteration
      counts, convergence status, and stopping reason.
- [x] Validate matrix dimensions, finite costs, strictly positive marginals,
      equal total mass, positive epsilon values, non-empty schedules, and
      positive iteration/check intervals.
- [x] Document the dense memory cost. Accelerator backends store both the cost
      matrix and its transpose.

### Accelerator setup and selection

Keep CUDA, AMDGPU, KernelAbstractions, and oneAPI as direct dependencies for the
four supported backends. Solving must check the requested accelerator and fail
clearly.

- [x] Declare CUDA in `Project.toml` and record a compatible version range.
- [x] Declare AMDGPU, KernelAbstractions, and oneAPI with compatible version ranges.
- [x] Check `CUDA.functional()` before preparing or allocating a mapping problem.
- [x] Report a clear unavailable-device error on machines without NVIDIA CUDA.
- [x] Support explicit `:cuda`, `:amdgpu`, `:oneapi`, and `:cpu` choices.
- [x] Do not silently change accelerator backends.
- [x] Document Intel Gen9 legacy-runtime installation and driver discovery.
- [x] Benchmark small and large CUDA problems on representative hardware.

### Remove unsupported solver families

Create regression tests first, then remove:

- [ ] The experimental quasi-Newton `curegot_solver` and sparse-Hessian code.
- [x] The package-level direct-CUDA comparison implementation.
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

- [x] Keep row-count-based eta selection in the cartogram layer, not the generic
      numerical solver.
- [x] Give ordinary users a documented regularization/sparsity preset rather
      than exposing every experimental parameter immediately.
- [x] Replace callbacks exposing raw GPU arrays with a backend-neutral stage
      observation interface.
- [x] Use the same authoritative host implementation for candidate row counting
      and final extraction, including deterministic ties and neighbor limits.
- [x] Replace ambiguous `min_weight` behavior with an explicit
      `minimum_source_share` rule used by both counting and extraction.
- [x] Report dense solver marginal error separately from mass dropped during
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
- [x] Run the CUDA-gated tests on NVIDIA hardware.
- [x] Add symmetric and asymmetric 2x2 transport problems.
- [x] Add a nonuniform 257x257 problem to exercise strided reductions beyond the
      256-workitem workgroup width and verify reconstructed host marginals.
- [x] Test convergence, explicit non-convergence, and stopping reasons on CUDA.
- [x] Test source-share normalization and population-weighted target marginals
      on CUDA.
- [x] Test sparse mass-loss reporting and automatic eta selection on CPU and
      CUDA when available.
- [x] Keep performance benchmarks separate from unit tests.

### oneAPI numerical tests

- [x] Run 1x1, rectangular, 257x257, continuation, and regional mapping tests on
      Intel UHD 620.
- [x] Test population-weighted target marginals on oneAPI.
- [x] Record the required Intel Gen9 legacy-driver environment variable.

### AMDGPU numerical tests

- [x] Add the `:amdgpu` backend and unavailable-device tests.
- [x] Reuse the CUDA/CPU numerical, regional, and automatic-eta test suites.
- [ ] Run the hardware-gated suite on a supported AMD GPU with ROCm 6 or newer.
- [ ] Record AMD GPU, ROCm, Julia, and AMDGPU.jl versions with benchmark results.

### Metal numerical tests

- [ ] Refactor vendor backends into optional package extensions before adding
      Metal.jl, avoiding an unusable hard dependency on non-macOS systems.
- [ ] Add a `:metal` backend using `Metal.MetalBackend()` and gate it with
      `Metal.functional()`.
- [ ] Run the numerical and image-parity checks on an Apple Silicon Mac.

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
- [x] Test the documented error when AMDGPU is unavailable.
- [ ] Add NVIDIA GPU CI for the numerical and end-to-end tests.
- [ ] Add AMDGPU CI if a suitable ROCm runner becomes available.
- [ ] Add oneAPI CI if a suitable Intel runner becomes available.
- [ ] Add Metal CI if a suitable Apple Silicon runner becomes available.

## 7. Retain H3 As An Advanced Input Path

H3 should enter before the shared five-column source contract:

```text
external H3 population rows
  -> validate H3 indexes and resolution
  -> optionally aggregate to parent cells
  -> assign countries
  -> calculate centre x/y
  -> id, population, x, y, country_code
  -> shared accelerator mapping pipeline
```

- [x] Preserve the H3 index in the generic `id` column.
- [x] Preserve the H3 `UInt64` identifier type in the country Arrow extract.
- [x] Make parent-resolution aggregation explicit and report its population
      totals.
- [x] Separate country assignment from generic mapping preparation.
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
- [x] Generate a deterministic `country-CODE-resN.arrow` filename consumed by
      the bounded comparison workflow.
- [ ] Replace instructions to "probably" change compression with tested,
      deterministic commands.
- [x] Keep these large inputs and generated country extracts outside the source
      repository.

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
- [x] Document the retained KernelAbstractions CUDA/AMDGPU/oneAPI/CPU paths.
- [x] State clearly that CPU uses the same kernels rather than a separate solver.
- [x] Document Intel Gen9 system package and Level Zero driver discovery.
- [x] Record the completed CUDA comparison methodology and results.
- [x] Document the centre-point approximation and spatial transform limitations.
- [x] Add an advanced prerequisites section for H3 data preparation rather than
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

Do not split the solver into another repository now. Keep the retained portable
implementation for CUDA, AMDGPU, oneAPI, and CPU in this package.

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
   retain the portable implementation.
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
