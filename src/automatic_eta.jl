const ETA_SCHEDULE = Float32[
    0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005,
    0.00002, 0.00001, 0.000001, 0.0000001,
]
const ETA_CANDIDATES = Float32[
    0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005, 0.00002, 0.00001,
    0.000001, 0.0000001,
]
const CUMULATIVE_WEIGHT = 0.995
const TARGET_ROWS_MULTIPLIER = 2
const MAX_ITERS_PER_ETA = 5_000
const SINKHORN_TOLERANCE = 0.02
const CHECK_EVERY = 100

function _source_weights(problem, result, source)
    logits = Vector{Float64}(undef, length(problem.target_mass))
    maximum_logit = -Inf
    @inbounds for target in eachindex(logits)
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

function _select_weights(weights, tie_keys; indices=false)
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
        count > 0 && retained >= CUMULATIVE_WEIGHT && break
        indices && push!(selected, target)
        retained += weights[target]
        count += 1
    end
    return (; count, selected)
end

function _sparse_stats(problem, result, sources, tie_keys)
    counts = Vector{Int}(undef, sources)
    Threads.@threads for source in 1:sources
        selection = _select_weights(_source_weights(problem, result, source), tie_keys)
        counts[source] = selection.count
    end
    return (; counts, rows=sum(counts))
end

function _extract_distribution(cartogram, sources, problem, result, stats, tie_keys)
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
        selection = _select_weights(source_weights, tie_keys; indices=true)
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

function _distribute(cartogram, sources, backend)
    target_rows = TARGET_ROWS_MULTIPLIER * (nrow(sources) + nrow(cartogram))
    problem = _prepare_problem(cartogram, sources)
    tie_keys = collect(zip(_coordinate_value.(cartogram.x), _coordinate_value.(cartogram.y)))
    best_result = nothing
    best_stats = nothing
    best_error = typemax(Int)

    function observe(result)
        result.converged || return false
        stats = _sparse_stats(problem, result, nrow(sources), tie_keys)
        row_error = abs(stats.rows - target_rows)
        if row_error < best_error
            best_result = result
            best_stats = stats
            best_error = row_error
        end
        return stats.rows <= target_rows
    end

    _solve_sinkhorn(
        problem,
        backend;
        eta_schedule=ETA_SCHEDULE,
        observed_etas=Set(ETA_CANDIDATES),
        observer=observe,
        max_iters_per_eta=MAX_ITERS_PER_ETA,
        tol=SINKHORN_TOLERANCE,
        check_every=CHECK_EVERY,
    )
    isnothing(best_result) && error("no eta candidate converged")
    return _extract_distribution(
        cartogram, sources, problem, best_result, best_stats, tie_keys,
    )
end
