const DEFAULT_ETA_BASE_SCHEDULE = Float32[
    0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005,
]
const DEFAULT_AUTO_ETA_CANDIDATES = Float32[
    0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005, 0.00002, 0.00001,
    0.000001, 0.0000001,
]

function _eta_values(values, label)
    collected = collect(values)
    all(value -> value isa Real && !(value isa Bool), collected) ||
        throw(ArgumentError("$label must contain real numbers"))
    result = Float32.(collected)
    isempty(result) && throw(ArgumentError("$label cannot be empty"))
    all(value -> isfinite(value) && value > 0, result) ||
        throw(ArgumentError("$label must contain finite positive Float32 values"))
    return result
end

function _eta_schedule(candidates, base_schedule)
    base = _eta_values(base_schedule, "base_eta_schedule")
    minimum_candidate = minimum(candidates)
    return sort!(unique!(vcat(filter(eta -> eta >= minimum_candidate, base), candidates)); rev=true)
end

function _sparse_options(targets; cumulative_weight, minimum_weight, minimum_cells, maximum_cells)
    !(cumulative_weight isa Bool) && isfinite(cumulative_weight) &&
        0 < cumulative_weight <= 1 ||
        throw(ArgumentError("cumulative_weight must be finite and in (0, 1]"))
    !(minimum_weight isa Bool) && isfinite(minimum_weight) && 0 <= minimum_weight <= 1 ||
        throw(ArgumentError("minimum_weight must be finite and in [0, 1]"))
    minimum_cells isa Integer && !(minimum_cells isa Bool) && 0 < minimum_cells <= targets ||
        throw(ArgumentError("minimum_cells must be between one and the cartogram size"))
    if !isnothing(maximum_cells)
        maximum_cells isa Integer && !(maximum_cells isa Bool) &&
            maximum_cells >= minimum_cells || throw(ArgumentError(
                "maximum_cells must be at least minimum_cells",
            ))
    end
    return (;
        cumulative_weight=Float64(cumulative_weight),
        minimum_weight=Float64(minimum_weight),
        minimum_cells=Int(minimum_cells),
        maximum_cells=isnothing(maximum_cells) ? targets : min(Int(maximum_cells), targets),
    )
end

function _source_weights(problem, result, source)
    logits = Vector{Float64}(undef, length(problem.target_mass))
    maximum_logit = -Inf
    @inbounds for target in eachindex(problem.target_mass)
        logit = (Float64(result.beta[target]) - Float64(_cost(problem, source, target))) /
                Float64(result.eta)
        logits[target] = logit
        maximum_logit = max(maximum_logit, logit)
    end
    total = 0.0
    @inbounds for target in eachindex(logits)
        weight = exp(logits[target] - maximum_logit)
        logits[target] = weight
        total += weight
    end
    isfinite(total) && total > 0 || error(
        "non-finite reconstructed weights at source row $source",
    )
    logits ./= total
    return logits
end

function _select_weights(weights, options, tie_keys; indices=false)
    order = sortperm(
        eachindex(weights);
        alg=MergeSort,
        lt=(left, right) -> weights[left] > weights[right] ||
                            (weights[left] == weights[right] &&
                             isless(tie_keys[left], tie_keys[right])),
    )
    selected = indices ? Int[] : nothing
    retained = 0.0
    count = 0
    for target in order
        if count >= options.minimum_cells &&
           (retained >= options.cumulative_weight || weights[target] <= 0 ||
            weights[target] < options.minimum_weight)
            break
        end
        indices && push!(selected, target)
        retained += weights[target]
        count += 1
        count >= options.maximum_cells && break
    end
    return (; count, retained=min(retained, 1.0), selected)
end

function _sparse_stats(problem, result, options, values, tie_keys)
    counts = Vector{Int}(undef, length(values))
    retained = Vector{Float64}(undef, length(values))
    Threads.@threads for source in eachindex(values)
        selection = _select_weights(
            _source_weights(problem, result, source), options, tie_keys,
        )
        counts[source] = selection.count
        retained[source] = selection.retained
    end
    scale = maximum(Float64.(values))
    scaled_values = Float64[Float64(value) / scale for value in values]
    retained_value = sum(scaled_values .* retained) / sum(scaled_values)
    return (; counts, rows=sum(counts), retained, retained_value)
end

function _extract_distribution(cartogram, sources, problem, result, options, stats, tie_keys)
    xs = Vector{eltype(cartogram.x)}(undef, stats.rows)
    ys = Vector{eltype(cartogram.y)}(undef, stats.rows)
    ids = Vector{eltype(sources.id)}(undef, stats.rows)
    target_rows = Vector{Int}(undef, stats.rows)
    scaled_transport = Vector{Float64}(undef, stats.rows)
    weights = Vector{Float64}(undef, stats.rows)
    row_ends = cumsum(stats.counts)
    value_scale = maximum(Float64.(sources.value))

    Threads.@threads for source in 1:nrow(sources)
        source_weights = _source_weights(problem, result, source)
        selection = _select_weights(source_weights, options, tie_keys; indices=true)
        selection.count == stats.counts[source] ||
            error("sparse row count changed during extraction")
        row = source == 1 ? 1 : row_ends[source - 1] + 1
        for target in selection.selected
            xs[row] = cartogram.x[target]
            ys[row] = cartogram.y[target]
            ids[row] = sources.id[source]
            target_rows[row] = target
            weights[row] = source_weights[target]
            scaled_transport[row] =
                Float64(sources.value[source]) / value_scale * source_weights[target]
            row += 1
        end
    end

    target_totals = zeros(Float64, nrow(cartogram))
    for row in eachindex(scaled_transport)
        target_totals[target_rows[row]] += scaled_transport[row]
    end
    weight_mean = [
        scaled_transport[row] / target_totals[target_rows[row]]
        for row in eachindex(scaled_transport)
    ]
    return DataFrame(x=xs, y=ys, id=ids, weight=weights, weight_mean=weight_mean)
end

function _fit_distribution(
    cartogram,
    sources,
    backend;
    cost_power::Real=2,
    cost_mode=:dense,
    candidate_etas=DEFAULT_AUTO_ETA_CANDIDATES,
    base_eta_schedule=DEFAULT_ETA_BASE_SCHEDULE,
    target_rows_multiplier::Real=2,
    minimum_retained_value::Real=0,
    cumulative_weight::Real=0.995,
    minimum_weight::Real=0,
    minimum_cells::Int=1,
    maximum_cells::Union{Nothing,Int}=nothing,
    max_iters_per_eta::Int=5_000,
    tol::Real=0.02,
    check_every::Int=100,
)
    !(target_rows_multiplier isa Bool) && isfinite(target_rows_multiplier) &&
        target_rows_multiplier > 0 ||
        throw(ArgumentError("target_rows_multiplier must be finite and positive"))
    !(minimum_retained_value isa Bool) && isfinite(minimum_retained_value) &&
        0 <= minimum_retained_value <= 1 ||
        throw(ArgumentError("minimum_retained_value must be finite and in [0, 1]"))
    candidates = sort!(unique!(_eta_values(candidate_etas, "candidate_etas")); rev=true)
    schedule = _eta_schedule(candidates, base_eta_schedule)
    options = _sparse_options(
        nrow(cartogram); cumulative_weight, minimum_weight, minimum_cells, maximum_cells,
    )
    target_rows = round(Int, target_rows_multiplier * (nrow(sources) + nrow(cartogram)))
    target_rows > 0 || throw(ArgumentError("target_rows_multiplier produces no rows"))
    problem = _prepare_problem(cartogram, sources; cost_power, cost_mode)
    tie_keys = collect(zip(_coordinate_value.(cartogram.x), _coordinate_value.(cartogram.y)))
    best_result = nothing
    best_stats = nothing
    best_error = typemax(Int)

    function observe(result)
        result.converged || return false
        stats = _sparse_stats(problem, result, options, sources.value, tie_keys)
        eligible = stats.retained_value >= minimum_retained_value
        row_error = abs(stats.rows - target_rows)
        if eligible && row_error < best_error
            best_result = result
            best_stats = stats
            best_error = row_error
        end
        return eligible && stats.rows <= target_rows
    end

    _solve_sinkhorn(
        problem,
        backend;
        eta_schedule=schedule,
        observed_etas=Set(candidates),
        observer=observe,
        max_iters_per_eta,
        tol,
        check_every,
    )
    isnothing(best_result) && error(
        "no converged eta candidate retained at least $minimum_retained_value of source value",
    )
    mapping = _extract_distribution(
        cartogram, sources, problem, best_result, options, best_stats, tie_keys,
    )
    return (;
        mapping,
        selected_eta=best_result.eta,
        retained_value=best_stats.retained_value,
        rows=best_stats.rows,
        target_rows,
    )
end

_distribute(args...; kwargs...) = _fit_distribution(args...; kwargs...).mapping
