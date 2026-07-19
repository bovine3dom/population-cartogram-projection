module PopulationCartogramProjection

using AMDGPU
using CSV
using CUDA
using DataFrames
import KernelAbstractions as KA
using KernelAbstractions: @index, @kernel, @localmem, @synchronize
using SHA
using TOML
using oneAPI

export IncompleteCountryFitError, MappingFit, MappingPlan, MultiCountryFit,
       canonicalize_h3_sources, canonicalize_sources, dominant_source_assignment,
       eta_continuation_schedule, eta_schedule_to, fit_mapping,
       fit_mapping_auto, fit_mapping_countries, load_owid_grid, place_source_labels,
       plan_mapping, project_extensive, project_intensive, project_ratio,
       reconcile_countries, save_fit, solve_sinkhorn, subdivide_grid,
       validate_sources

const SOURCE_COLUMNS = (:id, :population, :x, :y, :country_code)
const GRID_COLUMNS = (:cell_id, :grid_x, :grid_y, :country_code)
const DEFAULT_GRID_PATH = normpath(joinpath(@__DIR__, "..", "data", "cartogram.csv"))
const SINKHORN_WORKGROUP_SIZE = 256

struct SinkhornResult{T<:AbstractFloat}
    alpha::Vector{T}
    beta::Vector{T}
    eta::T
    marginal_error::Float64
    iterations::Int
    converged::Bool
    stop_reason::Symbol
end

"""A fitted mapping, per-source sparse retention, and auditable fit metadata."""
struct MappingFit{M<:AbstractDataFrame,R<:AbstractDataFrame,T}
    mapping::M
    source_retention::R
    metadata::T
end

struct MappingPlan{G<:AbstractDataFrame,T}
    grid::G
    metadata::T
end

struct MultiCountryFit{M<:AbstractDataFrame,R<:AbstractDataFrame,S<:AbstractDataFrame,C<:AbstractDataFrame,F,T}
    mapping::M
    source_retention::R
    sources::S
    country_statuses::C
    country_fits::F
    metadata::T
end

struct IncompleteCountryFitError{T} <: Exception
    result::T
end

struct MappingFitError <: Exception
    message::String
end

Base.showerror(io::IO, error::MappingFitError) = print(io, error.message)

function Base.showerror(io::IO, error::IncompleteCountryFitError)
    statuses = error.result.country_statuses
    incomplete = statuses[in.(statuses.status, Ref((:skipped, :failed))), :]
    print(
        io,
        "country fitting was incomplete: ",
        join(("$(row.input_country_code)=$(row.status)" for row in eachrow(incomplete)), ", "),
        "; inspect error.result.country_statuses or set allow_partial=true",
    )
end

"""
    canonicalize_h3_sources(table; id=:h3, population=:population,
                            country_code, resolution=nothing)

Validate H3 cells, optionally aggregate them to a parent resolution, and derive
canonical WGS84 centres. Requires the optional H3.jl extension.
"""
function canonicalize_h3_sources(args...; kwargs...)
    throw(ArgumentError("H3 extension is not loaded; install H3.jl and run `using H3` first"))
end

function _require_columns(table::AbstractDataFrame, required, label::AbstractString)
    available = Set(Symbol.(names(table)))
    missing_columns = filter(column -> column ∉ available, required)
    isempty(missing_columns) || throw(ArgumentError(
        "$label is missing required column(s): $(join(string.(missing_columns), ", "))",
    ))
end

"""
    validate_sources(sources)

Validate a nonempty canonical `id, population, x, y, country_code` table.
`(country_code, id)` must be unique, populations finite and positive, country
codes non-Boolean integers, and coordinates finite WGS84 longitude/latitude in
degrees. Returns `nothing` or throws `ArgumentError`.
"""
function validate_sources(sources::AbstractDataFrame)
    _require_columns(sources, SOURCE_COLUMNS, "source table")
    nrow(sources) > 0 || throw(ArgumentError("source table is empty"))

    any(ismissing, sources.id) && throw(ArgumentError("source id cannot be missing"))
    any(ismissing, sources.country_code) &&
        throw(ArgumentError("source country_code cannot be missing"))
    all(value -> value isa Integer && !(value isa Bool), sources.country_code) ||
        throw(ArgumentError("source country_code must contain integers"))
    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && value > 0, sources.population) ||
        throw(ArgumentError("source population must contain finite positive numbers"))

    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && -180 <= value <= 180, sources.x) ||
        throw(ArgumentError("source x must contain WGS84 longitudes in degrees between -180 and 180"))
    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && -90 <= value <= 90, sources.y) ||
        throw(ArgumentError("source y must contain WGS84 latitudes in degrees between -90 and 90"))

    keys = Set(zip(sources.country_code, sources.id))
    length(keys) == nrow(sources) ||
        throw(ArgumentError("(country_code, id) must uniquely identify each source row"))

    return nothing
end

function _source_column(table, selector, label)
    selector isa Symbol || selector isa AbstractString ||
        throw(ArgumentError("$label must name a source-table column"))
    column = Symbol(selector)
    column in propertynames(table) ||
        throw(ArgumentError("source table has no column named $column"))
    return column
end

"""
    canonicalize_sources(table; id=:id, population=:population, x=:x, y=:y,
                         country_code=:country_code)

Copy a source table into the canonical schema without making callers rename
columns. `country_code` may name a column or supply one integer for every row.
Unrelated columns are preserved. This validates but never drops or aggregates
rows.
"""
function canonicalize_sources(
    table::AbstractDataFrame;
    id=:id,
    population=:population,
    x=:x,
    y=:y,
    country_code=:country_code,
)
    id_column = _source_column(table, id, "id")
    population_column = _source_column(table, population, "population")
    x_column = _source_column(table, x, "x")
    y_column = _source_column(table, y, "y")
    country_is_value = country_code isa Integer && !(country_code isa Bool)
    country_code isa Bool && throw(ArgumentError("country_code cannot be Bool"))
    country_column = country_is_value ? nothing :
                     _source_column(table, country_code, "country_code")
    canonical_inputs = (
        id=id_column,
        population=population_column,
        x=x_column,
        y=y_column,
        country_code=country_column,
    )
    for (canonical, input) in pairs(canonical_inputs)
        canonical in propertynames(table) && input != canonical && throw(ArgumentError(
            "input column $canonical conflicts with the selected $canonical column",
        ))
    end
    selected_columns = filter(!isnothing, collect(values(canonical_inputs)))
    allunique(selected_columns) || throw(ArgumentError(
        "id, population, x, y, and country_code must use distinct input columns",
    ))

    sources = DataFrame(
        id=copy(table[!, id_column]),
        population=copy(table[!, population_column]),
        x=copy(table[!, x_column]),
        y=copy(table[!, y_column]),
        country_code=country_is_value ? fill(country_code, nrow(table)) :
                     copy(table[!, country_column]),
    )
    selected = Set(selected_columns)
    for column in propertynames(table)
        column in selected || column in SOURCE_COLUMNS ||
            (sources[!, column] = copy(table[!, column]))
    end
    validate_sources(sources)
    return sources
end

function _validate_grid(grid::AbstractDataFrame)
    _require_columns(grid, GRID_COLUMNS, "target grid")
    nrow(grid) > 0 || throw(ArgumentError("target grid is empty"))
    any(ismissing, grid.cell_id) && throw(ArgumentError("target cell_id cannot be missing"))
    allunique(grid.cell_id) || throw(ArgumentError("target cell_id must be unique"))
    all(value -> value isa Integer && !(value isa Bool), grid.country_code) ||
        throw(ArgumentError("target country_code must contain integers"))

    for column in (:grid_x, :grid_y)
        all(value -> value isa Real && !(value isa Bool) && isfinite(value), grid[!, column]) ||
            throw(ArgumentError("target $column must contain finite numbers"))
    end

    return nothing
end

"""
    load_owid_grid([path]; country_code=nothing)

Load the bundled OWID cartogram grid and assign stable cell identifiers.
`country_code` optionally filters its ISO 3166-1 numeric-style integer codes.
"""
function load_owid_grid(
    path::AbstractString=DEFAULT_GRID_PATH;
    country_code::Union{Nothing,Integer}=nothing,
)
    country_code isa Bool && throw(ArgumentError("country_code cannot be Bool"))
    isfile(path) || throw(ArgumentError("OWID grid not found at $path"))
    grid = CSV.read(
        path,
        DataFrame;
        header=[:grid_x, :grid_y, :country_code],
        types=Dict(:grid_x => Int, :grid_y => Int, :country_code => Int),
    )
    grid.cell_id = [
        string(lpad(string(country), 3, '0'), ':', x, ':', y)
        for (x, y, country) in zip(grid.grid_x, grid.grid_y, grid.country_code)
    ]
    select!(grid, GRID_COLUMNS...)
    if !isnothing(country_code)
        filter!(:country_code => ==(country_code), grid)
        nrow(grid) > 0 || throw(ArgumentError(
            "OWID grid has no cells for country_code=$country_code",
        ))
    end
    _validate_grid(grid)
    return grid
end

function _positive_int(value, label)
    value isa Integer && !(value isa Bool) && value > 0 ||
        throw(ArgumentError("$label must be a positive integer"))
    value <= typemax(Int) || throw(ArgumentError("$label exceeds typemax(Int)"))
    return Int(value)
end

"""
    subdivide_grid(grid; factor)
    subdivide_grid(grid; target_cells)

Replace every target cell with a uniform `factor` by `factor` child lattice.
Alternatively, choose the factor whose total is closest to `target_cells`.
The result includes deterministic `cell_id` values and `parent_cell_id`; all
parents receive the same number of children, preserving equal aggregate target
mass. Exactly one keyword must be supplied.
"""
function subdivide_grid(
    grid::AbstractDataFrame;
    factor=nothing,
    target_cells=nothing,
)
    _validate_grid(grid)
    xor(isnothing(factor), isnothing(target_cells)) || throw(ArgumentError(
        "supply exactly one of factor or target_cells",
    ))
    if !isnothing(target_cells)
        target_cells = _positive_int(target_cells, "target_cells")
        lower_factor = isqrt(fld(target_cells, nrow(grid)))
        candidates = unique(max.(1, [lower_factor, lower_factor + 1]))
        filter!(candidate -> big(nrow(grid)) * big(candidate)^2 <= typemax(Int), candidates)
        factor = first(sort!(candidates; by=candidate -> (
            abs(big(nrow(grid)) * big(candidate)^2 - target_cells), candidate,
        )))
    end
    factor = _positive_int(factor, "factor")

    if factor == 1
        result = select(grid, GRID_COLUMNS...)
        insertcols!(result, 2, :parent_cell_id => copy(result.cell_id))
        return result
    end

    step_x = _minimum_step(grid.grid_x)
    step_y = _minimum_step(grid.grid_y)
    factor_squared = Base.checked_mul(factor, factor)
    child_count = Base.checked_mul(nrow(grid), factor_squared)
    cell_ids = Vector{String}(undef, child_count)
    parent_cell_ids = Vector{eltype(grid.cell_id)}(undef, child_count)
    grid_x = Vector{Float64}(undef, child_count)
    grid_y = Vector{Float64}(undef, child_count)
    country_codes = Vector{eltype(grid.country_code)}(undef, child_count)

    row = 1
    for parent in eachrow(grid), i in 1:factor, j in 1:factor
        cell_ids[row] = string(parent.cell_id, ":sub", factor, ':', i, ':', j)
        parent_cell_ids[row] = parent.cell_id
        grid_x[row] = factor * Float64(parent.grid_x) + (2i - factor - 1) * step_x / 2
        grid_y[row] = factor * Float64(parent.grid_y) + (2j - factor - 1) * step_y / 2
        country_codes[row] = parent.country_code
        row += 1
    end
    result = DataFrame(
        cell_id=cell_ids,
        parent_cell_id=parent_cell_ids,
        grid_x=all(isinteger, grid_x) ? round.(Int, grid_x) : grid_x,
        grid_y=all(isinteger, grid_y) ? round.(Int, grid_y) : grid_y,
        country_code=country_codes,
    )
    _validate_grid(result)
    return result
end

include("projection.jl")
include("spatial.jl")
include("planning.jl")

function _float_eta_values(values, label)
    collected = collect(values)
    isempty(collected) && throw(ArgumentError("$label cannot be empty"))
    all(value -> value isa Real && !(value isa Bool), collected) ||
        throw(ArgumentError("$label must contain real numbers"))
    converted = Float32.(collected)
    all(value -> isfinite(value) && value > 0, converted) ||
        throw(ArgumentError("$label must contain finite positive values representable as Float32"))
    return converted
end

function _validate_sinkhorn_inputs(cost, source_mass, target_mass, eta_schedule, max_iters, tol, check_every)
    source_count, target_count = size(cost)
    source_count > 0 && target_count > 0 || throw(ArgumentError("cost matrix must be non-empty"))
    !(tol isa Bool) && isfinite(tol) && 0 < tol < 1 ||
        throw(ArgumentError("tol must be finite and between zero and one"))
    tol >= 10eps(Float32) ||
        throw(ArgumentError("tol must be at least $(10eps(Float32)) for the Float32 solver"))
    length(source_mass) == source_count || throw(DimensionMismatch("source mass does not match cost rows"))
    length(target_mass) == target_count || throw(DimensionMismatch("target mass does not match cost columns"))
    all(value -> isfinite(value) && value >= 0, cost) ||
        throw(ArgumentError("cost matrix must contain finite non-negative values"))
    all(value -> isfinite(value) && value > 0, source_mass) ||
        throw(ArgumentError("source mass must contain finite positive values"))
    all(value -> isfinite(value) && value > 0, target_mass) ||
        throw(ArgumentError("target mass must contain finite positive values"))
    source_total = sum(source_mass)
    target_total = sum(target_mass)
    isfinite(source_total) && source_total > 0 ||
        throw(ArgumentError("source mass total must be finite and positive"))
    isfinite(target_total) && target_total > 0 ||
        throw(ArgumentError("target mass total must be finite and positive"))
    mass_rtol = max(Float64(tol), 100eps(Float64))
    isapprox(source_total, target_total; atol=0, rtol=mass_rtol) ||
        throw(ArgumentError("source and target mass totals must match"))
    !isempty(eta_schedule) || throw(ArgumentError("eta_schedule cannot be empty"))
    all(value -> isfinite(value) && value > 0, eta_schedule) ||
        throw(ArgumentError("eta_schedule must contain finite positive values"))
    max_iters > 0 || throw(ArgumentError("max_iters_per_eta must be positive"))
    check_every > 0 || throw(ArgumentError("check_every must be positive"))
    return source_total, target_total
end

function _prepare_sinkhorn_inputs(
    cost,
    source_mass,
    target_mass,
    eta_schedule,
    max_iters_per_eta,
    tol,
    check_every,
)
    float_cost = cost isa Matrix{Float32} ? cost : Matrix{Float32}(cost)
    float_source_mass = source_mass isa Vector{Float32} ? source_mass : Vector{Float32}(source_mass)
    float_target_mass = Vector{Float32}(target_mass)
    float_eta_schedule = _float_eta_values(eta_schedule, "eta_schedule")
    source_total, target_total = _validate_sinkhorn_inputs(
        float_cost,
        float_source_mass,
        float_target_mass,
        float_eta_schedule,
        max_iters_per_eta,
        tol,
        check_every,
    )
    float_target_mass .*= source_total / target_total
    largest_target = argmax(float_target_mass)
    residual = source_total - sum(float_target_mass)
    if float_target_mass[largest_target] + residual > 0
        float_target_mass[largest_target] += residual
    end
    all(value -> isfinite(value) && value > 0, float_target_mass) ||
        throw(ArgumentError("target mass became invalid during Float32 normalization"))
    abs(sum(float_target_mass) - source_total) <= tol * source_total ||
        throw(ArgumentError("source and target mass totals cannot be matched in Float32"))
    return (; float_cost, float_source_mass, float_target_mass, float_eta_schedule)
end

function _run_sinkhorn(
    step!,
    marginal_error!,
    eta_schedule,
    max_iters_per_eta,
    tol,
    check_every;
    stage_observer=nothing,
)
    iterations = 0
    stage_state = nothing
    for eta in eta_schedule
        converged = false
        error_value = Inf
        for iteration in 1:max_iters_per_eta
            step!(eta)
            iterations += 1
            if iteration == 1 || iteration % check_every == 0 || iteration == max_iters_per_eta
                error_value = marginal_error!(eta)
                isfinite(error_value) || error(
                    "non-finite Sinkhorn marginal error at eta=$eta iteration=$iteration",
                )
                if error_value <= tol
                    converged = true
                    break
                end
            end
        end
        stage_state = (
            marginal_error=error_value,
            iterations=iterations,
            converged=converged,
            eta=eta,
            stop_reason=converged ? :converged : :max_iterations,
        )
        if !isnothing(stage_observer)
            stop = stage_observer(stage_state)
            stop isa Bool || throw(ArgumentError("stage_observer must return Bool"))
            stop && return merge(stage_state, (stop_reason=:stage_observer,))
        end
    end
    return stage_state
end

function _sinkhorn_result(alpha, beta, state)
    shift = beta[end]
    beta .-= shift
    alpha .+= shift
    all(isfinite, alpha) && all(isfinite, beta) || error("non-finite Sinkhorn dual potential")
    return SinkhornResult(
        alpha,
        beta,
        state.eta,
        state.marginal_error,
        state.iterations,
        state.converged,
        state.stop_reason,
    )
end

function _cuda_unavailable()
    return ArgumentError(
        "CUDA is not functional; an NVIDIA CUDA-capable GPU and driver are required",
    )
end

function _amdgpu_unavailable()
    return ArgumentError(
        "AMDGPU is not functional; a supported AMD GPU and ROCm/HIP installation are required",
    )
end

_amdgpu_functional() = AMDGPU.functional() && AMDGPU.has_rocm_gpu()

_optional_backend_loaded(::Val) = false
_optional_backend_functional(::Val) = false
_optional_ka_backend(::Val) = nothing

function _metal_unavailable()
    message = if _optional_backend_loaded(Val(:metal))
        "Metal is not functional; an Apple Silicon Mac with macOS 14 or newer is required"
    else
        "Metal backend extension is not loaded; install Metal.jl and run `using Metal` first"
    end
    return ArgumentError(message)
end

include("kernel_abstractions.jl")

function _prepare_mapping_problem(sources, grid; cost_power, backend)
    targets = _country_targets(sources, grid)
    _validate_backend(backend)
    problem = _prepare_problem(sources, targets; cost_power)
    return (; targets, problem)
end

function _validate_backend(backend)
    if backend === :cuda
        CUDA.functional() || throw(_cuda_unavailable())
    elseif backend === :amdgpu
        _amdgpu_functional() || throw(_amdgpu_unavailable())
    elseif backend === :metal
        _optional_backend_functional(Val(:metal)) || throw(_metal_unavailable())
    elseif backend === :oneapi
        oneAPI.functional() || throw(ArgumentError("oneAPI is not functional on this system"))
    elseif backend !== :cpu
        throw(ArgumentError("backend must be :cuda, :amdgpu, :metal, :oneapi, or :cpu"))
    end
    return nothing
end

function _extract_mapping(sources, targets, problem, result)
    source_count = nrow(sources)
    target_count = nrow(targets)
    row_count = source_count * target_count
    ids = Vector{eltype(sources.id)}(undef, row_count)
    country_codes = Vector{eltype(sources.country_code)}(undef, row_count)
    cell_ids = Vector{eltype(targets.cell_id)}(undef, row_count)
    source_shares = Vector{Float64}(undef, row_count)

    row = 1
    @inbounds for i in 1:source_count
        row_max = maximum((result.beta[j] - problem.cost[i, j]) / result.eta for j in 1:target_count)
        row_sum = sum(exp((result.beta[j] - problem.cost[i, j]) / result.eta - row_max) for j in 1:target_count)
        for j in 1:target_count
            ids[row] = sources.id[i]
            country_codes[row] = sources.country_code[i]
            cell_ids[row] = targets.cell_id[j]
            source_shares[row] = exp(
                (result.beta[j] - problem.cost[i, j]) / result.eta - row_max,
            ) / row_sum
            row += 1
        end
    end

    return DataFrame(
        id=ids,
        country_code=country_codes,
        cell_id=cell_ids,
        source_share=source_shares,
    )
end

include("automatic_eta.jl")

"""
    fit_mapping(sources, [grid]; backend, kwargs...)

Fit a dense fractional mapping from one country's weighted source centres to
the OWID cartogram grid. Returns a `MappingFit` containing `mapping`,
`source_retention`, and auditable solver/spatial `metadata`.
Callers must select `backend=:cuda`, `:amdgpu`, `:metal`, `:oneapi`, or `:cpu`
explicitly.
"""
function fit_mapping(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    backend::Symbol,
    cost_power::Real=2,
    eta_schedule=Float32[0.05, 0.02, 0.01, 0.005],
    max_iters_per_eta::Int=1_000,
    tol::Real=1e-5,
    check_every::Int=25,
)
    total_start = time()
    (; targets, problem) = _prepare_mapping_problem(sources, grid; cost_power, backend)
    solver_kwargs = (; eta_schedule, max_iters_per_eta, tol, check_every)
    result = nothing
    solver_seconds = @elapsed begin
        result = solve_sinkhorn(
            problem.cost,
            problem.source_mass,
            problem.target_mass;
            backend,
            solver_kwargs...,
        )
    end
    result.converged || throw(MappingFitError(
        "Sinkhorn failed to converge after $(result.iterations) iterations; " *
        "marginal error=$(result.marginal_error)",
    ))
    mapping = nothing
    extraction_seconds = @elapsed begin
        mapping = _extract_mapping(sources, targets, problem, result)
    end
    retained_shares = combine(
        groupby(mapping, [:country_code, :id]; sort=false),
        :source_share => sum => :retained_share,
    ).retained_share
    retained_shares = min.(retained_shares, 1.0)
    source_retention = DataFrame(
        id=copy(sources.id),
        country_code=copy(sources.country_code),
        neighbors=fill(nrow(targets), nrow(sources)),
        retained_share=retained_shares,
        dropped_share=1 .- retained_shares,
        cumulative_achieved=trues(nrow(sources)),
        truncation_reason=fill(:targets_exhausted, nrow(sources)),
    )
    population_scale = maximum(sources.population)
    population_weights = Float64.(sources.population) ./ population_scale
    retained_mass_share = sum(population_weights .* retained_shares) / sum(population_weights)
    metadata = (
        schema_version=1,
        fit_mode=:fixed,
        sources=nrow(sources),
        targets=nrow(targets),
        mapping_rows=nrow(mapping),
        rows=nrow(mapping),
        backend,
        cost_power=Float64(cost_power),
        selected_eta=result.eta,
        final_eta=result.eta,
        selected_iterations=result.iterations,
        iterations=result.iterations,
        marginal_error=result.marginal_error,
        converged=result.converged,
        stop_reason=result.stop_reason,
        spatial_transform=problem.spatial_metadata,
        retained_mass_share,
        dropped_mass_share=1 - retained_mass_share,
        minimum_retained_source_share=minimum(retained_shares),
        maximum_dropped_source_share=maximum(1 .- retained_shares),
        solver=(;
            eta_schedule=Float32.(eta_schedule),
            max_iters_per_eta,
            tolerance=Float64(tol),
            check_every,
        ),
        sparsification=nothing,
        timings=(;
            total_seconds=time() - total_start,
            solver_seconds,
            extraction_seconds,
        ),
    )
    return MappingFit(mapping, source_retention, metadata)
end

include("countries.jl")
include("persistence.jl")

end
