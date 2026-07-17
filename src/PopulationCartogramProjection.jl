module PopulationCartogramProjection

using AMDGPU
using CSV
using CUDA
using DataFrames
import KernelAbstractions as KA
using KernelAbstractions: @index, @kernel, @localmem, @synchronize
using oneAPI

export eta_continuation_schedule, eta_schedule_to, fit_mapping, fit_mapping_auto,
       load_owid_grid, solve_sinkhorn, validate_sources

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

function _require_columns(table::AbstractDataFrame, required, label::AbstractString)
    available = Set(Symbol.(names(table)))
    missing_columns = filter(column -> column ∉ available, required)
    isempty(missing_columns) || throw(ArgumentError(
        "$label is missing required column(s): $(join(string.(missing_columns), ", "))",
    ))
end

"""Validate the canonical `id, population, x, y, country_code` source table."""
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

"""Load the bundled OWID cartogram grid and assign stable cell identifiers."""
function load_owid_grid(path::AbstractString=DEFAULT_GRID_PATH)
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
    _validate_grid(grid)
    return grid
end

function _scale_to_grid(values, grid_values)
    source_min, source_max = extrema(values)
    target_min, target_max = extrema(grid_values)
    source_min == source_max && return fill((target_min + target_max) / 2, length(values))
    return target_min .+ (values .- source_min) .* ((target_max - target_min) / (source_max - source_min))
end

function _minimum_step(values)
    sorted_values = sort!(unique(Float64.(values)))
    return length(sorted_values) > 1 ? minimum(diff(sorted_values)) : 1.0
end

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

function _prepare_problem(sources::AbstractDataFrame, targets::AbstractDataFrame; cost_power::Real=2)
    !(cost_power isa Bool) && isfinite(cost_power) && cost_power > 0 ||
        throw(ArgumentError("cost_power must be finite and positive"))
    source_x = _scale_to_grid(Float64.(sources.x), Float64.(targets.grid_x))
    source_y = _scale_to_grid(-Float64.(sources.y), Float64.(targets.grid_y))
    step_x = _minimum_step(targets.grid_x)
    step_y = _minimum_step(targets.grid_y)

    source_count = nrow(sources)
    target_count = nrow(targets)
    cost = Matrix{Float32}(undef, source_count, target_count)
    Threads.@threads for j in 1:target_count
        @inbounds for i in 1:source_count
            dx = (source_x[i] - targets.grid_x[j]) / step_x
            dy = (source_y[i] - targets.grid_y[j]) / step_y
            cost[i, j] = Float32(hypot(dx, dy))
        end
    end

    max_distance = maximum(cost)
    if max_distance > 0
        cost .= (cost ./ max_distance) .^ cost_power
    end

    population_scale = maximum(sources.population)
    source_mass = Float32[value / population_scale for value in sources.population]
    all(isfinite, source_mass) || throw(ArgumentError("source population is too large to represent"))
    source_mass ./= sum(source_mass)
    target_mass = fill(inv(Float32(target_count)), target_count)
    target_mass ./= sum(target_mass)

    return (; cost, source_mass, target_mass)
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
    validate_sources(sources)
    _validate_grid(grid)

    country_codes = unique(sources.country_code)
    length(country_codes) == 1 || throw(ArgumentError("fit_mapping currently supports one country at a time"))
    country_code = only(country_codes)
    targets = filter(:country_code => ==(country_code), grid)
    nrow(targets) > 0 || throw(ArgumentError("OWID grid has no cells for country_code=$country_code"))
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

    return (; targets, problem=_prepare_problem(sources, targets; cost_power))
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
    fit_mapping(sources, [grid]; kwargs...)

Fit a dense fractional mapping from one country's weighted source centres to
the OWID cartogram grid. `sources` must contain `id`, `population`, `x`, `y`,
and `country_code`. The returned table contains `id`, `country_code`, `cell_id`,
and `source_share`, whose values sum to approximately one for each source.
Select `backend=:cuda`, `:amdgpu`, `:metal`, `:oneapi`, or `:cpu` explicitly
when needed.
"""
function fit_mapping(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    cost_power::Real=2,
    eta_schedule=Float32[0.05, 0.02, 0.01, 0.005],
    max_iters_per_eta::Int=1_000,
    tol::Real=1e-5,
    check_every::Int=25,
    backend::Symbol=:cuda,
)
    (; targets, problem) = _prepare_mapping_problem(sources, grid; cost_power, backend)
    solver_kwargs = (; eta_schedule, max_iters_per_eta, tol, check_every)
    result = solve_sinkhorn(
        problem.cost,
        problem.source_mass,
        problem.target_mass;
        backend,
        solver_kwargs...,
    )
    result.converged || error(
        "Sinkhorn failed to converge after $(result.iterations) iterations; " *
        "marginal error=$(result.marginal_error)",
    )
    return _extract_mapping(sources, targets, problem, result)
end

end
