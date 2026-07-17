const DEFAULT_ETA_BASE_SCHEDULE = Float32[
    0.05,
    0.02,
    0.01,
    0.005,
    0.002,
    0.001,
    0.0005,
    0.0002,
    0.0001,
    0.00005,
]
const DEFAULT_AUTO_ETA_CANDIDATES = Float32[
    0.005,
    0.002,
    0.001,
    0.0005,
    0.0002,
    0.0001,
    0.00005,
    0.00002,
    0.00001,
    0.000001,
    0.0000001,
]

"""Build a descending continuation schedule ending at `final_eta`."""
function eta_schedule_to(final_eta::Real; base_schedule=DEFAULT_ETA_BASE_SCHEDULE)
    final = only(_float_eta_values((final_eta,), "final_eta"))
    base = _float_eta_values(base_schedule, "base_schedule")
    return sort!(unique!(vcat(filter(eta -> eta >= final, base), final)); rev=true)
end

"""Build the descending warm-start schedule used for automatic eta tuning."""
function eta_continuation_schedule(
    candidate_final_etas;
    base_schedule=DEFAULT_ETA_BASE_SCHEDULE,
)
    candidates = _float_eta_values(candidate_final_etas, "candidate_final_etas")
    base = _float_eta_values(base_schedule, "base_schedule")
    minimum_candidate = minimum(candidates)
    return sort!(unique!(vcat(filter(eta -> eta >= minimum_candidate, base), candidates)); rev=true)
end

function _sparse_options(
    target_count;
    cumulative_share,
    minimum_source_share,
    minimum_neighbors,
    maximum_neighbors,
)
    !(cumulative_share isa Bool) && isfinite(cumulative_share) && 0 < cumulative_share <= 1 ||
        throw(ArgumentError("cumulative_share must be finite and in (0, 1]"))
    !(minimum_source_share isa Bool) && isfinite(minimum_source_share) &&
        0 <= minimum_source_share <= 1 ||
        throw(ArgumentError("minimum_source_share must be finite and in [0, 1]"))
    minimum_neighbors > 0 || throw(ArgumentError("minimum_neighbors must be positive"))
    minimum_neighbors <= target_count ||
        throw(ArgumentError("minimum_neighbors cannot exceed the target count"))
    if !isnothing(maximum_neighbors)
        maximum_neighbors > 0 || throw(ArgumentError("maximum_neighbors must be positive"))
        maximum_neighbors >= minimum_neighbors ||
            throw(ArgumentError("maximum_neighbors cannot be less than minimum_neighbors"))
    end
    return (
        cumulative_share=Float64(cumulative_share),
        minimum_source_share=Float64(minimum_source_share),
        minimum_neighbors,
        maximum_neighbors,
        maximum_neighbors_effective=isnothing(maximum_neighbors) ? target_count : min(maximum_neighbors, target_count),
    )
end

function _normalized_source_shares(cost, result, source_index)
    target_count = size(cost, 2)
    logits = Vector{Float64}(undef, target_count)
    row_max = -Inf
    @inbounds for target_index in 1:target_count
        value = (Float64(result.beta[target_index]) - Float64(cost[source_index, target_index])) /
                Float64(result.eta)
        logits[target_index] = value
        row_max = max(row_max, value)
    end
    row_sum = 0.0
    @inbounds for target_index in 1:target_count
        share = exp(logits[target_index] - row_max)
        logits[target_index] = share
        row_sum += share
    end
    isfinite(row_sum) && row_sum > 0 ||
        error("non-finite reconstructed source shares at source row $source_index")
    logits ./= row_sum
    return logits
end

function _select_sparse_row(shares, options; collect_indices=false, tie_keys=nothing)
    order = if isnothing(tie_keys)
        sortperm(shares; alg=MergeSort, rev=true)
    else
        sortperm(
            eachindex(shares);
            alg=MergeSort,
            lt=(left, right) -> shares[left] > shares[right] ||
                                (shares[left] == shares[right] &&
                                 isless(tie_keys[left], tie_keys[right])),
        )
    end
    selected = collect_indices ? Int[] : nothing
    retained_share = 0.0
    count = 0
    stop_reason = :targets_exhausted
    for target_index in order
        share = shares[target_index]
        if count >= options.minimum_neighbors
            if retained_share >= options.cumulative_share
                stop_reason = :cumulative_share
                break
            elseif share <= 0
                stop_reason = :numerical_zero
                break
            elseif share < options.minimum_source_share
                stop_reason = :minimum_source_share
                break
            end
        end
        collect_indices && push!(selected, target_index)
        retained_share += share
        count += 1
        if count >= options.maximum_neighbors_effective
            stop_reason = options.maximum_neighbors_effective < length(shares) ?
                          :maximum_neighbors : :targets_exhausted
            break
        end
    end
    cumulative_achieved = retained_share >= options.cumulative_share
    if cumulative_achieved
        stop_reason = :cumulative_share
    end
    return (; count, retained_share, cumulative_achieved, stop_reason, selected)
end

function _sparse_mapping_stats(problem, result, options, populations)
    source_count = size(problem.cost, 1)
    counts = Vector{Int}(undef, source_count)
    retained_shares = Vector{Float64}(undef, source_count)
    cumulative_achieved = Vector{Bool}(undef, source_count)
    stop_reasons = Vector{Symbol}(undef, source_count)
    Threads.@threads for source_index in 1:source_count
        shares = _normalized_source_shares(problem.cost, result, source_index)
        selected = _select_sparse_row(shares, options)
        counts[source_index] = selected.count
        retained_shares[source_index] = selected.retained_share
        cumulative_achieved[source_index] = selected.cumulative_achieved
        stop_reasons[source_index] = selected.stop_reason
    end
    population_scale = maximum(populations)
    population_weights = Float64[value / population_scale for value in populations]
    population_total = sum(population_weights)
    retained_mass_share = sum(
        population_weights[index] * retained_shares[index]
        for index in eachindex(retained_shares)
    ) / population_total
    return (;
        counts,
        retained_shares,
        cumulative_achieved,
        stop_reasons,
        rows=sum(counts),
        retained_mass_share,
    )
end

function _extract_sparse_mapping(sources, targets, problem, result, options, stats)
    ids = Vector{eltype(sources.id)}(undef, stats.rows)
    country_codes = Vector{eltype(sources.country_code)}(undef, stats.rows)
    cell_ids = Vector{eltype(targets.cell_id)}(undef, stats.rows)
    source_shares = Vector{Float64}(undef, stats.rows)
    row_ends = cumsum(stats.counts)
    tie_keys = string.(targets.cell_id)

    Threads.@threads for source_index in 1:nrow(sources)
        shares = _normalized_source_shares(problem.cost, result, source_index)
        selected = _select_sparse_row(
            shares,
            options;
            collect_indices=true,
            tie_keys,
        )
        selected.count == stats.counts[source_index] ||
            error("sparse row count changed during extraction")
        row = source_index == 1 ? 1 : row_ends[source_index - 1] + 1
        for target_index in selected.selected
            ids[row] = sources.id[source_index]
            country_codes[row] = sources.country_code[source_index]
            cell_ids[row] = targets.cell_id[target_index]
            source_shares[row] = shares[target_index]
            row += 1
        end
    end

    mapping = DataFrame(
        id=ids,
        country_code=country_codes,
        cell_id=cell_ids,
        source_share=source_shares,
    )
    source_retention = DataFrame(
        id=copy(sources.id),
        country_code=copy(sources.country_code),
        neighbors=stats.counts,
        retained_share=stats.retained_shares,
        dropped_share=1 .- stats.retained_shares,
        cumulative_achieved=stats.cumulative_achieved,
        truncation_reason=stats.stop_reasons,
    )
    return (; mapping, source_retention)
end

"""
    fit_mapping_auto(sources, [grid]; backend, kwargs...)

Tune the final Sinkhorn eta against a sparse output-row target while traversing
one warm-started continuation schedule. Candidate counts and final extraction
use the same deterministic host implementation. Returns `mapping`,
`source_retention`, and `metadata`.
"""
function fit_mapping_auto(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    backend::Symbol,
    cost_power::Real=2,
    candidate_final_etas=DEFAULT_AUTO_ETA_CANDIDATES,
    base_eta_schedule=DEFAULT_ETA_BASE_SCHEDULE,
    target_rows_multiplier::Real=2,
    cumulative_share::Real=0.995,
    minimum_source_share::Real=0,
    minimum_neighbors::Int=1,
    maximum_neighbors::Union{Nothing, Int}=nothing,
    max_iters_per_eta::Int=5_000,
    tol::Real=0.02,
    check_every::Int=100,
)
    total_start = time()
    !(target_rows_multiplier isa Bool) && isfinite(target_rows_multiplier) &&
        target_rows_multiplier > 0 ||
        throw(ArgumentError("target_rows_multiplier must be finite and positive"))
    candidates = sort!(unique!(_float_eta_values(candidate_final_etas, "candidate_final_etas")); rev=true)
    schedule = eta_continuation_schedule(candidates; base_schedule=base_eta_schedule)
    (; targets, problem) = _prepare_mapping_problem(sources, grid; cost_power, backend)
    options = _sparse_options(
        nrow(targets);
        cumulative_share,
        minimum_source_share,
        minimum_neighbors,
        maximum_neighbors,
    )
    target_rows = round(Int, target_rows_multiplier * (nrow(sources) + nrow(targets)))
    target_rows > 0 || throw(ArgumentError("target_rows_multiplier produces a zero row target"))

    candidate_results = NamedTuple[]
    failed_candidates = NamedTuple[]
    best_result = nothing
    best_candidate = nothing
    best_stats = nothing
    candidate_count_seconds = 0.0
    function observe_stage(result)
        if !result.converged
            failure = (
                final_eta=result.eta,
                marginal_error=result.marginal_error,
                iterations=result.iterations,
                stop_reason=result.stop_reason,
            )
            push!(failed_candidates, failure)
            push!(candidate_results, merge(failure, (
                converged=false,
                rows=missing,
                target_rows,
                row_error=missing,
                retained_mass_share=missing,
            )))
            return false
        end
        stats = nothing
        candidate_count_seconds += @elapsed begin
            stats = _sparse_mapping_stats(problem, result, options, sources.population)
        end
        candidate = (
            final_eta=result.eta,
            marginal_error=result.marginal_error,
            iterations=result.iterations,
            converged=result.converged,
            stop_reason=result.stop_reason,
            rows=stats.rows,
            target_rows,
            row_error=abs(stats.rows - target_rows),
            retained_mass_share=stats.retained_mass_share,
        )
        push!(candidate_results, candidate)
        if isnothing(best_candidate) || candidate.row_error < best_candidate.row_error
            best_result = result
            best_candidate = candidate
            best_stats = stats
        end
        return candidate.rows <= target_rows
    end

    solver_result = nothing
    solver_and_tuning_seconds = @elapsed begin
        solver_result = solve_sinkhorn(
            problem.cost,
            problem.source_mass,
            problem.target_mass;
            backend,
            eta_schedule=schedule,
            max_iters_per_eta,
            tol,
            check_every,
            stage_observer=observe_stage,
            stage_observer_etas=candidates,
        )
    end
    isnothing(best_result) && error("no converged eta candidate was evaluated")

    stats = best_stats
    extracted = nothing
    sparse_extraction_seconds = @elapsed begin
        extracted = _extract_sparse_mapping(sources, targets, problem, best_result, options, stats)
    end
    metadata = merge(best_candidate, (
        sources=nrow(sources),
        targets=nrow(targets),
        candidate_final_etas=candidates,
        planned_eta_schedule=schedule,
        evaluated_eta_schedule=schedule[1:findfirst(==(solver_result.eta), schedule)],
        candidates=candidate_results,
        failed_candidates,
        selected_eta=best_candidate.final_eta,
        selected_iterations=best_candidate.iterations,
        selected_stop_reason=best_candidate.stop_reason,
        solver_final_eta=solver_result.eta,
        solver_final_iterations=solver_result.iterations,
        solver_final_converged=solver_result.converged,
        solver_stop_reason=solver_result.stop_reason,
        backend,
        cost_power=Float64(cost_power),
        target_rows_multiplier=Float64(target_rows_multiplier),
        cumulative_share=options.cumulative_share,
        minimum_source_share=options.minimum_source_share,
        minimum_neighbors=options.minimum_neighbors,
        maximum_neighbors=options.maximum_neighbors,
        maximum_neighbors_effective=options.maximum_neighbors_effective,
        timings=(
            total_seconds=time() - total_start,
            solver_and_tuning_seconds,
            candidate_count_seconds,
            sparse_extraction_seconds,
        ),
        retained_mass_share=stats.retained_mass_share,
        dropped_mass_share=1 - stats.retained_mass_share,
        minimum_retained_source_share=minimum(stats.retained_shares),
        maximum_dropped_source_share=maximum(1 .- stats.retained_shares),
        sources_below_cumulative_share=count(!, stats.cumulative_achieved),
    ))
    return (
        mapping=extracted.mapping,
        source_retention=extracted.source_retention,
        metadata=metadata,
    )
end
