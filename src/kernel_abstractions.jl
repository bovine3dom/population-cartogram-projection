@kernel unsafe_indices=true function _matrix_free_reduce!(
    output,
    output_x_hi,
    output_x_lo,
    output_y_hi,
    output_y_lo,
    reduction_x_hi,
    reduction_x_lo,
    reduction_y_hi,
    reduction_y_lo,
    output_dual,
    reduction_dual,
    mass,
    eta,
    inverse_distance_scale,
    outputs,
    reductions,
    output_offset,
    ::Val{UPDATE},
) where {UPDATE}
    _, output_group = @index(Group, NTuple)
    lane, output_lane = @index(Local, NTuple)
    output_index = output_offset +
                   (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
    valid_output = output_index <= outputs
    state = @private Float32 (6,)
    state[1] = valid_output ? output_x_hi[output_index] : 0.0f0
    state[2] = valid_output ? output_x_lo[output_index] : 0.0f0
    state[3] = valid_output ? output_y_hi[output_index] : 0.0f0
    state[4] = valid_output ? output_y_lo[output_index] : 0.0f0
    state[5] = -Inf32
    state[6] = 0.0f0
    tile_x_hi = @localmem Float32 (MATRIX_FREE_REDUCTION_LANES,)
    tile_x_lo = @localmem Float32 (MATRIX_FREE_REDUCTION_LANES,)
    tile_y_hi = @localmem Float32 (MATRIX_FREE_REDUCTION_LANES,)
    tile_y_lo = @localmem Float32 (MATRIX_FREE_REDUCTION_LANES,)
    maxima = @localmem Float32 (
        MATRIX_FREE_REDUCTION_LANES, MATRIX_FREE_OUTPUTS_PER_GROUP,
    )
    totals = @localmem Float32 (
        MATRIX_FREE_REDUCTION_LANES, MATRIX_FREE_OUTPUTS_PER_GROUP,
    )

    for tile in 0:((reductions - 1) ÷ MATRIX_FREE_REDUCTION_LANES)
        reduction_index = tile * MATRIX_FREE_REDUCTION_LANES + lane
        if output_lane == 1
            if reduction_index <= reductions
                tile_x_hi[lane] = reduction_x_hi[reduction_index]
                tile_x_lo[lane] = reduction_x_lo[reduction_index]
                tile_y_hi[lane] = reduction_y_hi[reduction_index]
                tile_y_lo[lane] = reduction_y_lo[reduction_index]
            else
                tile_x_hi[lane] = 0.0f0
                tile_x_lo[lane] = 0.0f0
                tile_y_hi[lane] = 0.0f0
                tile_y_lo[lane] = 0.0f0
            end
        end
        @synchronize

        reduction_index = tile * MATRIX_FREE_REDUCTION_LANES + lane
        output_index = output_offset +
                       (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
        if output_index <= outputs && reduction_index <= reductions
            cost = _matrix_free_cost(
                state[1],
                state[2],
                state[3],
                state[4],
                tile_x_hi[lane],
                tile_x_lo[lane],
                tile_y_hi[lane],
                tile_y_lo[lane],
                inverse_distance_scale,
            )
            score = reduction_dual[reduction_index] - cost
            UPDATE || (score += output_dual[output_index])
            if state[6] == 0
                state[5] = score
                state[6] = 1.0f0
            elseif score <= state[5]
                state[6] += exp((score - state[5]) / eta)
            else
                state[6] = state[6] * exp((state[5] - score) / eta) + 1.0f0
                state[5] = score
            end
        end
        @synchronize
    end

    maxima[lane, output_lane] = state[5]
    totals[lane, output_lane] = state[6]
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            right_total = totals[lane + offset, output_lane]
            if right_total > 0
                left_total = totals[lane, output_lane]
                right_maximum = maxima[lane + offset, output_lane]
                if left_total == 0
                    maxima[lane, output_lane] = right_maximum
                    totals[lane, output_lane] = right_total
                else
                    left_maximum = maxima[lane, output_lane]
                    if right_maximum <= left_maximum
                        totals[lane, output_lane] = left_total + right_total *
                            exp((right_maximum - left_maximum) / eta)
                    else
                        maxima[lane, output_lane] = right_maximum
                        totals[lane, output_lane] = right_total + left_total *
                            exp((left_maximum - right_maximum) / eta)
                    end
                end
            end
        end
        @synchronize
    end

    output_index = output_offset +
                   (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
    if lane == 1 && output_index <= outputs
        maximum_value = maxima[1, output_lane]
        total = totals[1, output_lane]
        if UPDATE
            output[output_index] = eta * log(mass[output_index]) - maximum_value -
                                   eta * log(total)
        else
            output[output_index] = maximum_value / eta + log(total)
        end
    end
end

function _copy_to_backend(backend, source)
    destination = KA.allocate(backend, eltype(source), size(source))
    GC.@preserve source begin
        KA.copyto!(backend, destination, source)
        KA.synchronize(backend)
    end
    return destination
end

function _copy_to_host!(backend, destination, source)
    GC.@preserve destination begin
        KA.copyto!(backend, destination, source)
        KA.synchronize(backend)
    end
    return destination
end

function _snapshot(backend, beta, eta, converged)
    host_beta = _copy_to_host!(backend, Vector{Float32}(undef, length(beta)), beta)
    all(isfinite, host_beta) ||
        error("non-finite Sinkhorn dual potential")
    return SinkhornResult(host_beta, eta, converged)
end

function _marginal_error(log_marginals, expected)
    total = 0.0
    maximum_log = log(floatmax(Float64))
    for index in eachindex(expected)
        log_value = Float64(log_marginals[index])
        value = log_value == -Inf ? 0.0 : log_value > maximum_log ? Inf : exp(log_value)
        total += abs(value - Float64(expected[index]))
    end
    return total
end

function _run_sinkhorn(
    source_mass,
    target_mass,
    backend,
    beta,
    row_sums,
    column_sums,
    row_update!,
    column_update!,
    row_marginals!,
    column_marginals!;
    eta_schedule,
    observed_etas,
    observer,
    max_iters_per_eta,
    tol,
    check_every,
)
    host_rows = Vector{Float32}(undef, length(source_mass))
    host_columns = Vector{Float32}(undef, length(target_mass))
    total_iterations = 0
    diagnostics = nothing
    for eta in eta_schedule
        converged = false
        marginal_error = Inf
        for iteration in 1:max_iters_per_eta
            total_iterations += 1
            row_update!(eta)
            column_update!(eta)
            if iteration == 1 || iteration % check_every == 0 || iteration == max_iters_per_eta
                row_marginals!(eta)
                column_marginals!(eta)
                _copy_to_host!(backend, host_rows, row_sums)
                _copy_to_host!(backend, host_columns, column_sums)
                marginal_error = (
                    _marginal_error(host_rows, source_mass) +
                    _marginal_error(host_columns, target_mass)
                ) / sum(source_mass)
                isnan(marginal_error) && error(
                    "non-finite Sinkhorn marginal error at eta=$eta iteration=$iteration",
                )
                if marginal_error <= tol
                    converged = true
                    break
                end
            end
        end
        diagnostics = (;
            iterations=total_iterations,
            eta,
            converged,
            marginal_error,
        )
        if eta in observed_etas
            observer(_snapshot(backend, beta, eta, converged)) && return diagnostics
        end
    end
    return diagnostics
end

function _matrix_free_cpu_value(
    problem,
    output_dual,
    reduction_dual,
    mass,
    eta,
    output_index,
    reductions,
    ::Val{SOURCE_OUTPUT},
    ::Val{UPDATE},
) where {SOURCE_OUTPUT,UPDATE}
    maximum_value = -Inf32
    total = 0.0
    @inbounds for reduction_index in 1:reductions
        source = SOURCE_OUTPUT ? output_index : reduction_index
        target = SOURCE_OUTPUT ? reduction_index : output_index
        score = reduction_dual[reduction_index] - _cost(problem, source, target)
        UPDATE || (score += output_dual[output_index])
        if total == 0
            maximum_value = score
            total = 1.0
        elseif score <= maximum_value
            total += exp(Float64(score - maximum_value) / Float64(eta))
        else
            total = total * exp(Float64(maximum_value - score) / Float64(eta)) + 1.0
            maximum_value = score
        end
    end
    normalizer = maximum_value + eta * log(total)
    return UPDATE ? eta * log(mass[output_index]) - normalizer : normalizer / eta
end

function _matrix_free_cpu_reduce!(
    output,
    problem,
    output_dual,
    reduction_dual,
    mass,
    eta,
    reductions,
    source_output,
    update,
)
    Threads.@threads for output_index in eachindex(output)
        output[output_index] = _matrix_free_cpu_value(
            problem,
            output_dual,
            reduction_dual,
            mass,
            eta,
            output_index,
            reductions,
            source_output,
            update,
        )
    end
    return nothing
end

function _solve_sinkhorn(problem::MatrixFreeProblem, backend::KA.CPU; kwargs...)
    sources = length(problem.source_mass)
    targets = length(problem.target_mass)
    alpha = zeros(Float32, sources)
    beta = zeros(Float32, targets)
    row_sums = Vector{Float32}(undef, sources)
    column_sums = Vector{Float32}(undef, targets)
    row_update!(eta) = _matrix_free_cpu_reduce!(
        alpha, problem, alpha, beta, problem.source_mass, eta, targets, Val(true), Val(true),
    )
    column_update!(eta) = _matrix_free_cpu_reduce!(
        beta, problem, beta, alpha, problem.target_mass, eta, sources, Val(false), Val(true),
    )
    row_marginals!(eta) = _matrix_free_cpu_reduce!(
        row_sums, problem, alpha, beta, problem.source_mass, eta, targets, Val(true), Val(false),
    )
    column_marginals!(eta) = _matrix_free_cpu_reduce!(
        column_sums,
        problem,
        beta,
        alpha,
        problem.target_mass,
        eta,
        sources,
        Val(false),
        Val(false),
    )
    return _run_sinkhorn(
        problem.source_mass,
        problem.target_mass,
        backend,
        beta,
        row_sums,
        column_sums,
        row_update!,
        column_update!,
        row_marginals!,
        column_marginals!;
        kwargs...,
    )
end

function _matrix_free_chunk_size(reductions)
    chunk_size = max(
        MATRIX_FREE_OUTPUTS_PER_GROUP,
        fld(MATRIX_FREE_MAX_PAIRS_PER_LAUNCH, reductions),
    )
    return chunk_size - mod(chunk_size, MATRIX_FREE_OUTPUTS_PER_GROUP)
end

function _launch_matrix_free!(
    reduce!,
    inverse_distance_scale,
    output,
    output_coordinates,
    reduction_coordinates,
    output_dual,
    reduction_dual,
    mass,
    eta,
    outputs,
    reductions,
    update,
)
    chunk_size = _matrix_free_chunk_size(reductions)
    for output_offset in 0:chunk_size:(outputs - 1)
        chunk_outputs = min(chunk_size, outputs - output_offset)
        reduce!(
            output,
            output_coordinates...,
            reduction_coordinates...,
            output_dual,
            reduction_dual,
            mass,
            eta,
            inverse_distance_scale,
            outputs,
            reductions,
            output_offset,
            update;
            ndrange=(MATRIX_FREE_REDUCTION_LANES, chunk_outputs),
        )
    end
    return nothing
end

function _matrix_free_device_data(problem, backend)
    source_coordinates = map(
        coordinates -> _copy_to_backend(backend, coordinates),
        (problem.source_x_hi, problem.source_x_lo, problem.source_y_hi, problem.source_y_lo),
    )
    target_coordinates = map(
        coordinates -> _copy_to_backend(backend, coordinates),
        (problem.target_x_hi, problem.target_x_lo, problem.target_y_hi, problem.target_y_lo),
    )
    return (;
        source_coordinates,
        target_coordinates,
        source_mass=_copy_to_backend(backend, problem.source_mass),
        target_mass=_copy_to_backend(backend, problem.target_mass),
    )
end

function _solve_exact_sinkhorn(problem::MatrixFreeProblem, backend; kwargs...)
    sources = length(problem.source_mass)
    targets = length(problem.target_mass)
    device = _matrix_free_device_data(problem, backend)
    alpha = KA.zeros(backend, Float32, sources)
    beta = KA.zeros(backend, Float32, targets)
    row_sums = KA.allocate(backend, Float32, sources)
    column_sums = KA.allocate(backend, Float32, targets)
    reduce! = _matrix_free_reduce!(
        backend, (MATRIX_FREE_REDUCTION_LANES, MATRIX_FREE_OUTPUTS_PER_GROUP),
    )
    launch!(args...) = _launch_matrix_free!(reduce!, problem.inverse_distance_scale, args...)
    row_update!(eta) = launch!(
        alpha, device.source_coordinates, device.target_coordinates, alpha, beta,
        device.source_mass, eta, sources, targets, Val(true),
    )
    column_update!(eta) = launch!(
        beta, device.target_coordinates, device.source_coordinates, beta, alpha,
        device.target_mass, eta, targets, sources, Val(true),
    )
    row_marginals!(eta) = launch!(
        row_sums, device.source_coordinates, device.target_coordinates, alpha, beta,
        device.source_mass, eta, sources, targets, Val(false),
    )
    column_marginals!(eta) = launch!(
        column_sums, device.target_coordinates, device.source_coordinates, beta, alpha,
        device.target_mass, eta, targets, sources, Val(false),
    )
    return _run_sinkhorn(
        problem.source_mass,
        problem.target_mass,
        backend,
        beta,
        row_sums,
        column_sums,
        row_update!,
        column_update!,
        row_marginals!,
        column_marginals!;
        kwargs...,
    )
end
