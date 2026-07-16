module PopulationCartogramProjection

using CSV
using CUDA
using DataFrames
import KernelAbstractions as KA
using KernelAbstractions: @index, @kernel, @localmem, @synchronize
using oneAPI

export fit_mapping, load_owid_grid, solve_sinkhorn, solve_sinkhorn_cuda, solve_sinkhorn_ka, validate_sources

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

    for column in (:x, :y)
        all(value -> value isa Real && !(value isa Bool) && isfinite(value), sources[!, column]) ||
            throw(ArgumentError("source $column must contain finite numbers"))
    end

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

function _prepare_problem(sources::AbstractDataFrame, targets::AbstractDataFrame; cost_power::Real=2)
    !(cost_power isa Bool) && isfinite(cost_power) && cost_power > 0 ||
        throw(ArgumentError("cost_power must be finite and positive"))
    source_x = _scale_to_grid(Float64.(sources.x), Float64.(targets.grid_x))
    source_y = _scale_to_grid(Float64.(sources.y), Float64.(targets.grid_y))
    step_x = _minimum_step(targets.grid_x)
    step_y = _minimum_step(targets.grid_y)

    source_count = nrow(sources)
    target_count = nrow(targets)
    cost = Matrix{Float32}(undef, source_count, target_count)
    @inbounds for j in 1:target_count
        for i in 1:source_count
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
        throw(ArgumentError("tol must be at least $(10eps(Float32)) for the Float32 CUDA solver"))
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
    eta_values = collect(eta_schedule)
    any(value -> value isa Bool, eta_values) &&
        throw(ArgumentError("eta_schedule cannot contain boolean values"))
    float_cost = cost isa Matrix{Float32} ? cost : Matrix{Float32}(cost)
    float_source_mass = source_mass isa Vector{Float32} ? source_mass : Vector{Float32}(source_mass)
    float_target_mass = Vector{Float32}(target_mass)
    float_eta_schedule = Float32.(eta_values)
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

function _run_sinkhorn(step!, marginal_error!, eta_schedule, max_iters_per_eta, tol, check_every)
    error_value = Inf
    iterations = 0
    converged = false
    for eta in eta_schedule
        converged = false
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
    end
    return (; marginal_error=error_value, iterations, converged)
end

function _sinkhorn_result(alpha, beta, eta_schedule, state)
    shift = beta[end]
    beta .-= shift
    alpha .+= shift
    all(isfinite, alpha) && all(isfinite, beta) || error("non-finite Sinkhorn dual potential")
    return SinkhornResult(
        alpha,
        beta,
        eta_schedule[end],
        state.marginal_error,
        state.iterations,
        state.converged,
        state.converged ? :converged : :max_iterations,
    )
end

include("kernel_abstractions.jl")

function _sinkhorn_row_kernel!(transposed_cost, alpha, beta, eta, source_mass, target_count)
    source_index = blockIdx().x
    thread_index = threadIdx().x
    thread_count = blockDim().x
    shared = CUDA.CuDynamicSharedArray(eltype(transposed_cost), thread_count)

    row_max = -Inf32
    target_index = thread_index
    while target_index <= target_count
        row_max = max(row_max, beta[target_index] - transposed_cost[target_index, source_index])
        target_index += thread_count
    end
    shared[thread_index] = row_max
    CUDA.sync_threads()

    offset = thread_count >>> 1
    while offset >= 1
        if thread_index <= offset
            shared[thread_index] = max(shared[thread_index], shared[thread_index + offset])
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    row_max = shared[1]
    CUDA.sync_threads()
    row_sum = 0.0f0
    target_index = thread_index
    while target_index <= target_count
        row_sum += exp(
            (beta[target_index] - transposed_cost[target_index, source_index] - row_max) / eta,
        )
        target_index += thread_count
    end
    shared[thread_index] = row_sum
    CUDA.sync_threads()

    offset = thread_count >>> 1
    while offset >= 1
        if thread_index <= offset
            shared[thread_index] += shared[thread_index + offset]
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    if thread_index == 1
        alpha[source_index] =
            eta * log(source_mass[source_index]) - row_max - eta * log(shared[1])
    end
    return nothing
end

function _sinkhorn_column_kernel!(cost, alpha, beta, eta, target_mass, source_count)
    target_index = blockIdx().x
    thread_index = threadIdx().x
    thread_count = blockDim().x
    shared = CUDA.CuDynamicSharedArray(eltype(cost), thread_count)

    column_max = -Inf32
    source_index = thread_index
    while source_index <= source_count
        column_max = max(column_max, alpha[source_index] - cost[source_index, target_index])
        source_index += thread_count
    end
    shared[thread_index] = column_max
    CUDA.sync_threads()

    offset = thread_count >>> 1
    while offset >= 1
        if thread_index <= offset
            shared[thread_index] = max(shared[thread_index], shared[thread_index + offset])
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    column_max = shared[1]
    CUDA.sync_threads()
    column_sum = 0.0f0
    source_index = thread_index
    while source_index <= source_count
        column_sum += exp(
            (alpha[source_index] - cost[source_index, target_index] - column_max) / eta,
        )
        source_index += thread_count
    end
    shared[thread_index] = column_sum
    CUDA.sync_threads()

    offset = thread_count >>> 1
    while offset >= 1
        if thread_index <= offset
            shared[thread_index] += shared[thread_index + offset]
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    if thread_index == 1
        beta[target_index] =
            eta * log(target_mass[target_index]) - column_max - eta * log(shared[1])
    end
    return nothing
end

function _marginal_kernel!(
    cost,
    alpha,
    beta,
    eta,
    row_sums,
    column_sums,
    source_count,
    target_count,
    target_tile_count,
)
    thread_x = threadIdx().x
    thread_y = threadIdx().y
    tile_index = blockIdx().x - 1
    target_tile = rem(tile_index, target_tile_count)
    source_tile = div(tile_index, target_tile_count)
    source_index = source_tile * blockDim().y + thread_y
    target_index = target_tile * blockDim().x + thread_x
    shared_columns = CUDA.CuDynamicSharedArray(eltype(cost), 256)

    mass = zero(eltype(cost))
    if source_index <= source_count && target_index <= target_count
        mass = exp(
            (alpha[source_index] + beta[target_index] - cost[source_index, target_index]) / eta,
        )
    end

    row_mass = mass
    for offset in (16, 8, 4, 2, 1)
        row_mass += CUDA.shfl_down_sync(0xffffffff, row_mass, offset)
    end
    if thread_x == 1 && source_index <= source_count
        CUDA.@atomic row_sums[source_index] += row_mass
    end

    shared_columns[thread_x + (thread_y - 1) * 32] = mass
    CUDA.sync_threads()
    if thread_y == 1 && target_index <= target_count
        column_mass = zero(eltype(cost))
        for local_y in 1:8
            column_mass += shared_columns[thread_x + (local_y - 1) * 32]
        end
        CUDA.@atomic column_sums[target_index] += column_mass
    end
    return nothing
end

function _cuda_unavailable()
    return ArgumentError(
        "CUDA is not functional; an NVIDIA CUDA-capable GPU and driver are required",
    )
end

function _marginal_error!(row_sums, column_sums, alpha, beta, cost, source_mass, target_mass, eta)
    CUDA.fill!(row_sums, 0.0f0)
    CUDA.fill!(column_sums, 0.0f0)
    source_count, target_count = size(cost)
    threads = (32, 8)
    target_tile_count = cld(target_count, 32)
    blocks = target_tile_count * cld(source_count, 8)
    CUDA.@cuda threads=threads blocks=blocks shmem=256 * sizeof(Float32) _marginal_kernel!(
        cost,
        alpha,
        beta,
        eta,
        row_sums,
        column_sums,
        source_count,
        target_count,
        target_tile_count,
    )
    absolute_error = sum(abs.(row_sums .- source_mass)) +
                     sum(abs.(column_sums .- target_mass))
    return Float64(absolute_error / sum(source_mass))
end

function solve_sinkhorn_cuda(
    cost,
    source_mass,
    target_mass;
    eta_schedule=Float32[0.05, 0.02, 0.01, 0.005],
    max_iters_per_eta::Int=1_000,
    tol::Real=1e-5,
    check_every::Int=25,
)
    problem = _prepare_sinkhorn_inputs(
        cost,
        source_mass,
        target_mass,
        eta_schedule,
        max_iters_per_eta,
        tol,
        check_every,
    )
    CUDA.functional() || throw(_cuda_unavailable())

    (; float_cost, float_source_mass, float_target_mass, float_eta_schedule) = problem
    source_count, target_count = size(float_cost)
    cost_gpu = CuArray(float_cost)
    transposed_cost_gpu = CuArray(Matrix(transpose(float_cost)))
    source_mass_gpu = CuArray(float_source_mass)
    target_mass_gpu = CuArray(float_target_mass)
    alpha_gpu = CUDA.zeros(Float32, source_count)
    beta_gpu = CUDA.zeros(Float32, target_count)
    row_sums_gpu = similar(alpha_gpu)
    column_sums_gpu = similar(beta_gpu)
    threads = SINKHORN_WORKGROUP_SIZE
    shared_memory = threads * sizeof(Float32)
    function step!(eta)
        CUDA.@cuda threads=threads blocks=source_count shmem=shared_memory _sinkhorn_row_kernel!(
            transposed_cost_gpu,
            alpha_gpu,
            beta_gpu,
            eta,
            source_mass_gpu,
            target_count,
        )
        CUDA.@cuda threads=threads blocks=target_count shmem=shared_memory _sinkhorn_column_kernel!(
            cost_gpu,
            alpha_gpu,
            beta_gpu,
            eta,
            target_mass_gpu,
            source_count,
        )
    end
    marginal_error!(eta) = _marginal_error!(
        row_sums_gpu,
        column_sums_gpu,
        alpha_gpu,
        beta_gpu,
        cost_gpu,
        source_mass_gpu,
        target_mass_gpu,
        eta,
    )
    state = _run_sinkhorn(
        step!,
        marginal_error!,
        float_eta_schedule,
        max_iters_per_eta,
        tol,
        check_every,
    )
    return _sinkhorn_result(Array(alpha_gpu), Array(beta_gpu), float_eta_schedule, state)
end

solve_sinkhorn(args...; kwargs...) = solve_sinkhorn_cuda(args...; kwargs...)

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

"""
    fit_mapping(sources, [grid]; kwargs...)

Fit a dense fractional mapping from one country's weighted source centres to
the OWID cartogram grid. `sources` must contain `id`, `population`, `x`, `y`,
and `country_code`. The returned table contains `id`, `country_code`, `cell_id`,
and `source_share`, whose values sum to approximately one for each source.
Select `implementation=:cuda`, `:ka_cuda`, `:ka_oneapi`, or `:ka_cpu` while
implementations are being compared.
"""
function fit_mapping(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    cost_power::Real=2,
    eta_schedule=Float32[0.05, 0.02, 0.01, 0.005],
    max_iters_per_eta::Int=1_000,
    tol::Real=1e-5,
    check_every::Int=25,
    implementation::Symbol=:cuda,
)
    validate_sources(sources)
    _validate_grid(grid)

    country_codes = unique(sources.country_code)
    length(country_codes) == 1 || throw(ArgumentError("fit_mapping currently supports one country at a time"))
    country_code = only(country_codes)
    targets = filter(:country_code => ==(country_code), grid)
    nrow(targets) > 0 || throw(ArgumentError("OWID grid has no cells for country_code=$country_code"))
    if implementation === :cuda || implementation === :ka_cuda
        CUDA.functional() || throw(_cuda_unavailable())
    elseif implementation === :ka_oneapi
        oneAPI.functional() || throw(ArgumentError("oneAPI is not functional on this system"))
    elseif implementation !== :ka_cpu
        throw(ArgumentError("implementation must be :cuda, :ka_cuda, :ka_oneapi, or :ka_cpu"))
    end

    problem = _prepare_problem(sources, targets; cost_power)
    solver_kwargs = (; eta_schedule, max_iters_per_eta, tol, check_every)
    result = if implementation === :cuda
        solve_sinkhorn_cuda(problem.cost, problem.source_mass, problem.target_mass; solver_kwargs...)
    else
        backend = if implementation === :ka_cuda
            :cuda
        elseif implementation === :ka_oneapi
            :oneapi
        else
            :cpu
        end
        solve_sinkhorn_ka(
            problem.cost,
            problem.source_mass,
            problem.target_mass;
            backend,
            solver_kwargs...,
        )
    end
    result.converged || error(
        "Sinkhorn failed to converge after $(result.iterations) iterations; " *
        "marginal error=$(result.marginal_error)",
    )
    return _extract_mapping(sources, targets, problem, result)
end

end
