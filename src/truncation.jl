const TRUNCATION_BLOCK_SIZE = MATRIX_FREE_REDUCTION_LANES
const TRUNCATION_COARSE_BLOCKS = 8
const TRUNCATION_COARSE_SIZE = TRUNCATION_BLOCK_SIZE * TRUNCATION_COARSE_BLOCKS
const TRUNCATION_BOUND_GUARD = 64eps(Float32)

struct BlockBounds
    minimum_x::Vector{Float32}
    maximum_x::Vector{Float32}
    minimum_y::Vector{Float32}
    maximum_y::Vector{Float32}
end

struct SpatialBlocks
    indices::Vector{Int32}
    leaf::BlockBounds
    coarse::BlockBounds
end

struct TruncatedProblem
    exact::MatrixFreeProblem
    source_blocks::SpatialBlocks
    target_blocks::SpatialBlocks
    tolerance::Float32
    maximum_eta::Float32
end

@inline _cost(problem::TruncatedProblem, source, target) =
    _cost(problem.exact, source, target)
@inline _target_mass(problem::TruncatedProblem) = problem.exact.target_mass

function _float32_down(value)
    converted = Float32(value)
    return converted > value ? prevfloat(converted) : converted
end

function _float32_up(value)
    converted = Float32(value)
    return converted < value ? nextfloat(converted) : converted
end

function _truncation_log_budget(count, tolerance)
    value = log(Float64(count) * (1 - Float64(tolerance)) / Float64(tolerance))
    return _float32_up(value)
end

@inline function _spread_morton_bits(value::UInt32)
    value &= 0x0000ffff
    value = (value | value << 8) & 0x00ff00ff
    value = (value | value << 4) & 0x0f0f0f0f
    value = (value | value << 2) & 0x33333333
    return (value | value << 1) & 0x55555555
end

function _block_bounds(x, y, permutation, block_size)
    blocks = cld(length(permutation), block_size)
    minimum_x = Vector{Float32}(undef, blocks)
    maximum_x = similar(minimum_x)
    minimum_y = similar(minimum_x)
    maximum_y = similar(minimum_x)
    @inbounds for block in 1:blocks
        first_index = (block - 1) * block_size + 1
        last_index = min(block * block_size, length(permutation))
        members = @view permutation[first_index:last_index]
        minimum_x[block] = prevfloat(Float32(minimum(index -> x[index], members)))
        maximum_x[block] = nextfloat(Float32(maximum(index -> x[index], members)))
        minimum_y[block] = prevfloat(Float32(minimum(index -> y[index], members)))
        maximum_y[block] = nextfloat(Float32(maximum(index -> y[index], members)))
    end
    return BlockBounds(minimum_x, maximum_x, minimum_y, maximum_y)
end

function _spatial_blocks(x_hi, x_lo, y_hi, y_lo)
    x = Float64.(x_hi) .+ Float64.(x_lo)
    y = Float64.(y_hi) .+ Float64.(y_lo)
    x_minimum, x_maximum = extrema(x)
    y_minimum, y_maximum = extrema(y)
    span_x = x_maximum - x_minimum
    span_y = y_maximum - y_minimum
    keys = Vector{UInt32}(undef, length(x))
    @inbounds for index in eachindex(x)
        scaled_x = span_x == 0 ? 0.0 : (x[index] - x_minimum) / span_x
        scaled_y = span_y == 0 ? 0.0 : (y[index] - y_minimum) / span_y
        integer_x = round(UInt32, clamp(scaled_x, 0, 1) * typemax(UInt16))
        integer_y = round(UInt32, clamp(scaled_y, 0, 1) * typemax(UInt16))
        keys[index] = _spread_morton_bits(integer_x) |
                      (_spread_morton_bits(integer_y) << 1)
    end
    permutation = Int32.(sortperm(keys; alg=MergeSort))
    return SpatialBlocks(
        permutation,
        _block_bounds(x, y, permutation, TRUNCATION_BLOCK_SIZE),
        _block_bounds(x, y, permutation, TRUNCATION_COARSE_SIZE),
    )
end

function _prepare_truncated_problem(problem; tolerance, maximum_eta)
    isfinite(tolerance) && 0 < tolerance < 1 || throw(ArgumentError(
        "truncation_tolerance is outside the supported Float32 range",
    ))
    isfinite(maximum_eta) && maximum_eta > 0 || throw(ArgumentError(
        "truncation_eta is outside the supported Float32 range",
    ))
    source_blocks = _spatial_blocks(
        problem.source_x_hi,
        problem.source_x_lo,
        problem.source_y_hi,
        problem.source_y_lo,
    )
    target_blocks = _spatial_blocks(
        problem.target_x_hi,
        problem.target_x_lo,
        problem.target_y_hi,
        problem.target_y_lo,
    )
    return TruncatedProblem(problem, source_blocks, target_blocks, tolerance, maximum_eta)
end

@inline function _block_lower_cost(
    x_hi,
    x_lo,
    y_hi,
    y_lo,
    minimum_x,
    maximum_x,
    minimum_y,
    maximum_y,
    inverse_distance_scale,
)
    x = x_hi + x_lo
    y = y_hi + y_lo
    dx = max(minimum_x - x, x - maximum_x, 0.0f0)
    dy = max(minimum_y - y, y - maximum_y, 0.0f0)
    normalized = muladd(dx, dx, dy * dy) * inverse_distance_scale
    return min(max(normalized - TRUNCATION_BOUND_GUARD, 0.0f0), 1.0f0)
end

@kernel unsafe_indices=true function _block_maximum!(
    output,
    dual,
    indices,
    reductions,
)
    block = @index(Group, Linear)
    lane = @index(Local, Linear)
    position = (block - 1) * TRUNCATION_BLOCK_SIZE + lane
    values = @localmem Float32 (TRUNCATION_BLOCK_SIZE,)
    values[lane] = position <= reductions ? dual[indices[position]] : -Inf32
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        lane <= offset && (values[lane] = max(values[lane], values[lane + offset]))
        @synchronize
    end
    lane == 1 && (output[block] = values[1])
end

@kernel unsafe_indices=true function _coarse_maximum!(output, leaf_maximum, leaf_count)
    coarse = @index(Global, Linear)
    if coarse <= length(output)
        first_leaf = (coarse - 1) * TRUNCATION_COARSE_BLOCKS + 1
        last_leaf = min(coarse * TRUNCATION_COARSE_BLOCKS, leaf_count)
        maximum_value = -Inf32
        for leaf in first_leaf:last_leaf
            maximum_value = max(maximum_value, leaf_maximum[leaf])
        end
        output[coarse] = maximum_value
    end
end

@kernel unsafe_indices=true function _truncated_reduce!(
    output,
    output_indices,
    output_x_hi,
    output_x_lo,
    output_y_hi,
    output_y_lo,
    reduction_x_hi,
    reduction_x_lo,
    reduction_y_hi,
    reduction_y_lo,
    reduction_indices,
    leaf_minimum_x,
    leaf_maximum_x,
    leaf_minimum_y,
    leaf_maximum_y,
    leaf_dual_maximum,
    coarse_minimum_x,
    coarse_maximum_x,
    coarse_minimum_y,
    coarse_maximum_y,
    coarse_dual_maximum,
    output_dual,
    reduction_dual,
    mass,
    eta,
    inverse_distance_scale,
    log_budget,
    outputs,
    reductions,
    output_offset,
    active_block_counts,
    evaluated_pair_counts,
    ::Val{UPDATE},
) where {UPDATE}
    _, output_group = @index(Group, NTuple)
    lane, output_lane = @index(Local, NTuple)
    output_position = output_offset +
                      (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
    valid_output = output_position <= outputs
    output_index = valid_output ? output_indices[output_position] : Int32(1)
    state = @private Float32 (7,)
    state[1] = valid_output ? output_x_hi[output_index] : 0.0f0
    state[2] = valid_output ? output_x_lo[output_index] : 0.0f0
    state[3] = valid_output ? output_y_hi[output_index] : 0.0f0
    state[4] = valid_output ? output_y_lo[output_index] : 0.0f0
    anchor = @private Int64 (1,)
    anchor[1] = 1
    counters = @private UInt64 (2,)
    counters[1] = 0
    counters[2] = 0
    leaf_count = length(leaf_dual_maximum)
    coarse_count = length(coarse_dual_maximum)
    maxima = @localmem Float32 (
        TRUNCATION_BLOCK_SIZE, MATRIX_FREE_OUTPUTS_PER_GROUP,
    )
    totals = @localmem Float32 (
        TRUNCATION_BLOCK_SIZE, MATRIX_FREE_OUTPUTS_PER_GROUP,
    )
    block_indices = @localmem Int64 (
        TRUNCATION_BLOCK_SIZE, MATRIX_FREE_OUTPUTS_PER_GROUP,
    )
    tile_x_hi = @localmem Float32 (TRUNCATION_BLOCK_SIZE,)
    tile_x_lo = @localmem Float32 (TRUNCATION_BLOCK_SIZE,)
    tile_y_hi = @localmem Float32 (TRUNCATION_BLOCK_SIZE,)
    tile_y_lo = @localmem Float32 (TRUNCATION_BLOCK_SIZE,)
    tile_dual = @localmem Float32 (TRUNCATION_BLOCK_SIZE,)
    coarse_active_rows = @localmem UInt32 (MATRIX_FREE_OUTPUTS_PER_GROUP,)
    active_rows = @localmem UInt32 (MATRIX_FREE_OUTPUTS_PER_GROUP,)
    active_group = @localmem UInt32 (1,)

    best_upper = -Inf32
    best_block = Int64(1)
    for block in lane:TRUNCATION_BLOCK_SIZE:coarse_count
        upper = coarse_dual_maximum[block] - _block_lower_cost(
            state[1],
            state[2],
            state[3],
            state[4],
            coarse_minimum_x[block],
            coarse_maximum_x[block],
            coarse_minimum_y[block],
            coarse_maximum_y[block],
            inverse_distance_scale,
        )
        if upper > best_upper || (upper == best_upper && block < best_block)
            best_upper = upper
            best_block = block
        end
    end
    maxima[lane, output_lane] = valid_output ? best_upper : -Inf32
    block_indices[lane, output_lane] = best_block
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            right_maximum = maxima[lane + offset, output_lane]
            right_block = block_indices[lane + offset, output_lane]
            if right_maximum > maxima[lane, output_lane] ||
               (right_maximum == maxima[lane, output_lane] &&
                right_block < block_indices[lane, output_lane])
                maxima[lane, output_lane] = right_maximum
                block_indices[lane, output_lane] = right_block
            end
        end
        @synchronize
    end
    anchor[1] = block_indices[1, output_lane]

    leaf = (anchor[1] - 1) * TRUNCATION_COARSE_BLOCKS + lane
    leaf_upper = -Inf32
    if lane <= TRUNCATION_COARSE_BLOCKS && leaf <= leaf_count
        leaf_upper = leaf_dual_maximum[leaf] - _block_lower_cost(
            state[1],
            state[2],
            state[3],
            state[4],
            leaf_minimum_x[leaf],
            leaf_maximum_x[leaf],
            leaf_minimum_y[leaf],
            leaf_maximum_y[leaf],
            inverse_distance_scale,
        )
    end
    maxima[lane, output_lane] = leaf_upper
    block_indices[lane, output_lane] = leaf
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            right_maximum = maxima[lane + offset, output_lane]
            right_block = block_indices[lane + offset, output_lane]
            if right_maximum > maxima[lane, output_lane] ||
               (right_maximum == maxima[lane, output_lane] &&
                right_block < block_indices[lane, output_lane])
                maxima[lane, output_lane] = right_maximum
                block_indices[lane, output_lane] = right_block
            end
        end
        @synchronize
    end
    anchor[1] = block_indices[1, output_lane]

    anchor_position = (anchor[1] - 1) * TRUNCATION_BLOCK_SIZE + lane
    anchor_score = -Inf32
    output_position = output_offset +
                      (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
    output_index = output_position <= outputs ? output_indices[output_position] : Int32(1)
    if output_position <= outputs && anchor_position <= reductions
        reduction_index = reduction_indices[anchor_position]
        anchor_score = reduction_dual[reduction_index] - _matrix_free_cost(
            state[1],
            state[2],
            state[3],
            state[4],
            reduction_x_hi[reduction_index],
            reduction_x_lo[reduction_index],
            reduction_y_hi[reduction_index],
            reduction_y_lo[reduction_index],
            inverse_distance_scale,
        )
    end
    maxima[lane, output_lane] = anchor_score
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        lane <= offset && (maxima[lane, output_lane] = max(
            maxima[lane, output_lane], maxima[lane + offset, output_lane],
        ))
        @synchronize
    end
    state[5] = maxima[1, output_lane] - TRUNCATION_BOUND_GUARD
    state[6] = -Inf32
    state[7] = 0.0f0

    for coarse in 1:coarse_count
        if lane == 1
            output_position = output_offset +
                              (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
            upper = coarse_dual_maximum[coarse] - _block_lower_cost(
                state[1],
                state[2],
                state[3],
                state[4],
                coarse_minimum_x[coarse],
                coarse_maximum_x[coarse],
                coarse_minimum_y[coarse],
                coarse_maximum_y[coarse],
                inverse_distance_scale,
            )
            coarse_active_rows[output_lane] = ifelse(
                output_position <= outputs &&
                (coarse == cld(anchor[1], TRUNCATION_COARSE_BLOCKS) ||
                 upper + eta * log_budget + TRUNCATION_BOUND_GUARD >= state[5]),
                UInt32(1),
                UInt32(0),
            )
        end
        @synchronize
        if lane == 1 && output_lane == 1
            group_active = UInt32(0)
            for row in 1:MATRIX_FREE_OUTPUTS_PER_GROUP
                group_active |= coarse_active_rows[row]
            end
            active_group[1] = group_active
        end
        @synchronize

        if active_group[1] != 0
            first_leaf = (coarse - 1) * TRUNCATION_COARSE_BLOCKS + 1
            last_leaf = min(coarse * TRUNCATION_COARSE_BLOCKS, leaf_count)
            for block in first_leaf:last_leaf
                position = (block - 1) * TRUNCATION_BLOCK_SIZE + lane
                if lane == 1
                    upper = leaf_dual_maximum[block] - _block_lower_cost(
                        state[1],
                        state[2],
                        state[3],
                        state[4],
                        leaf_minimum_x[block],
                        leaf_maximum_x[block],
                        leaf_minimum_y[block],
                        leaf_maximum_y[block],
                        inverse_distance_scale,
                    )
                    active_rows[output_lane] = ifelse(
                        coarse_active_rows[output_lane] != 0 &&
                        (block == anchor[1] ||
                         upper + eta * log_budget + TRUNCATION_BOUND_GUARD >= state[5]),
                        UInt32(1),
                        UInt32(0),
                    )
                end
                if output_lane == 1
                    if position <= reductions
                        reduction_index = reduction_indices[position]
                        tile_x_hi[lane] = reduction_x_hi[reduction_index]
                        tile_x_lo[lane] = reduction_x_lo[reduction_index]
                        tile_y_hi[lane] = reduction_y_hi[reduction_index]
                        tile_y_lo[lane] = reduction_y_lo[reduction_index]
                        tile_dual[lane] = reduction_dual[reduction_index]
                    else
                        tile_x_hi[lane] = 0.0f0
                        tile_x_lo[lane] = 0.0f0
                        tile_y_hi[lane] = 0.0f0
                        tile_y_lo[lane] = 0.0f0
                        tile_dual[lane] = -Inf32
                    end
                end
                @synchronize

                output_position = output_offset +
                                  (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP +
                                  output_lane
                output_index = output_position <= outputs ?
                               output_indices[output_position] : Int32(1)
                if active_rows[output_lane] != 0 && output_position <= outputs &&
                   position <= reductions
                    score = tile_dual[lane] - _matrix_free_cost(
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
                    UPDATE || (score += output_dual[output_index])
                    if state[7] == 0
                        state[6] = score
                        state[7] = 1.0f0
                    elseif score <= state[6]
                        state[7] += exp((score - state[6]) / eta)
                    else
                        state[7] = state[7] * exp((state[6] - score) / eta) + 1.0f0
                        state[6] = score
                    end
                end
                if lane == 1 && active_rows[output_lane] != 0
                    counters[1] += 1
                    counters[2] += Base.unsafe_trunc(UInt64, min(
                        TRUNCATION_BLOCK_SIZE,
                        reductions - (block - 1) * TRUNCATION_BLOCK_SIZE,
                    ))
                end
                @synchronize
            end
        end
        @synchronize
    end

    maxima[lane, output_lane] = state[6]
    totals[lane, output_lane] = state[7]
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

    output_position = output_offset +
                      (output_group - 1) * MATRIX_FREE_OUTPUTS_PER_GROUP + output_lane
    output_index = output_position <= outputs ? output_indices[output_position] : Int32(1)
    if lane == 1 && output_position <= outputs
        maximum_value = maxima[1, output_lane]
        total = totals[1, output_lane]
        if UPDATE
            output[output_index] = eta * log(mass[output_index]) - maximum_value -
                                   eta * log(total)
        else
            output[output_index] = maximum_value / eta + log(total)
        end
        active_block_counts[output_index] += counters[1]
        evaluated_pair_counts[output_index] += counters[2]
    end
end

function _copy_block_bounds(backend, bounds)
    return (;
        minimum_x=_copy_to_backend(backend, bounds.minimum_x),
        maximum_x=_copy_to_backend(backend, bounds.maximum_x),
        minimum_y=_copy_to_backend(backend, bounds.minimum_y),
        maximum_y=_copy_to_backend(backend, bounds.maximum_y),
    )
end

function _copy_spatial_blocks(backend, blocks)
    return (;
        indices=_copy_to_backend(backend, blocks.indices),
        leaf=_copy_block_bounds(backend, blocks.leaf),
        coarse=_copy_block_bounds(backend, blocks.coarse),
    )
end

function _solve_sinkhorn_impl(problem::TruncatedProblem, backend::KA.CPU; kwargs...)
    return _solve_sinkhorn_impl(problem.exact, backend; kwargs...)
end

function _solve_sinkhorn_impl(problem::TruncatedProblem, backend; kwargs...)
    exact = problem.exact
    sources = length(exact.source_mass)
    targets = length(exact.target_mass)
    device = _matrix_free_device_data(exact, backend)
    source_blocks = _copy_spatial_blocks(backend, problem.source_blocks)
    target_blocks = _copy_spatial_blocks(backend, problem.target_blocks)
    source_leaf_maxima = KA.allocate(
        backend, Float32, length(problem.source_blocks.leaf.minimum_x),
    )
    source_coarse_maxima = KA.allocate(
        backend, Float32, length(problem.source_blocks.coarse.minimum_x),
    )
    target_leaf_maxima = KA.allocate(
        backend, Float32, length(problem.target_blocks.leaf.minimum_x),
    )
    target_coarse_maxima = KA.allocate(
        backend, Float32, length(problem.target_blocks.coarse.minimum_x),
    )
    source_active_blocks = KA.zeros(backend, UInt64, sources)
    source_evaluated_pairs = KA.zeros(backend, UInt64, sources)
    target_active_blocks = KA.zeros(backend, UInt64, targets)
    target_evaluated_pairs = KA.zeros(backend, UInt64, targets)
    alpha = KA.zeros(backend, Float32, sources)
    beta = KA.zeros(backend, Float32, targets)
    row_sums = KA.allocate(backend, Float32, sources)
    column_sums = KA.allocate(backend, Float32, targets)
    exact_reduce! = _matrix_free_reduce!(
        backend, (MATRIX_FREE_REDUCTION_LANES, MATRIX_FREE_OUTPUTS_PER_GROUP),
    )
    truncated_reduce! = _truncated_reduce!(
        backend, (TRUNCATION_BLOCK_SIZE, MATRIX_FREE_OUTPUTS_PER_GROUP),
    )
    block_maximum! = _block_maximum!(backend, TRUNCATION_BLOCK_SIZE)
    coarse_maximum! = _coarse_maximum!(backend)
    source_log_budget = _truncation_log_budget(sources, problem.tolerance)
    target_log_budget = _truncation_log_budget(targets, problem.tolerance)
    current_eta = Ref(NaN32)
    truncated_iteration = Ref(false)
    truncated_row_updates = Ref(0)
    truncated_column_updates = Ref(0)
    exact_row_audits = Ref(0)
    exact_column_audits = Ref(0)

    exact_launch!(args...) = _launch_matrix_free!(
        exact_reduce!, exact.inverse_distance_scale, args...,
    )
    function refresh!(leaf_output, coarse_output, dual, blocks, reductions)
        block_maximum!(
            leaf_output, dual, blocks.indices, reductions;
            ndrange=length(leaf_output) * TRUNCATION_BLOCK_SIZE,
        )
        coarse_maximum!(
            coarse_output, leaf_output, length(leaf_output);
            ndrange=length(coarse_output),
        )
        return nothing
    end
    function truncated_launch!(
        output,
        output_coordinates,
        output_blocks,
        reduction_coordinates,
        reduction_blocks,
        leaf_maxima,
        coarse_maxima,
        output_dual,
        reduction_dual,
        mass,
        eta,
        log_budget,
        outputs,
        reductions,
        active_counts,
        pair_counts,
    )
        chunk_size = _matrix_free_chunk_size(reductions)
        for output_offset in 0:chunk_size:(outputs - 1)
            chunk_outputs = min(chunk_size, outputs - output_offset)
            truncated_reduce!(
                output,
                output_blocks.indices,
                output_coordinates...,
                reduction_coordinates...,
                reduction_blocks.indices,
                reduction_blocks.leaf.minimum_x,
                reduction_blocks.leaf.maximum_x,
                reduction_blocks.leaf.minimum_y,
                reduction_blocks.leaf.maximum_y,
                leaf_maxima,
                reduction_blocks.coarse.minimum_x,
                reduction_blocks.coarse.maximum_x,
                reduction_blocks.coarse.minimum_y,
                reduction_blocks.coarse.maximum_y,
                coarse_maxima,
                output_dual,
                reduction_dual,
                mass,
                eta,
                exact.inverse_distance_scale,
                log_budget,
                outputs,
                reductions,
                output_offset,
                active_counts,
                pair_counts,
                Val(true);
                ndrange=(TRUNCATION_BLOCK_SIZE, chunk_outputs),
            )
        end
        return nothing
    end
    function row_update!(eta)
        new_stage = eta != current_eta[]
        current_eta[] = eta
        truncated_iteration[] = eta <= problem.maximum_eta && !new_stage
        if truncated_iteration[]
            truncated_row_updates[] += 1
            refresh!(target_leaf_maxima, target_coarse_maxima, beta, target_blocks, targets)
            truncated_launch!(
                alpha,
                device.source_coordinates,
                source_blocks,
                device.target_coordinates,
                target_blocks,
                target_leaf_maxima,
                target_coarse_maxima,
                alpha,
                beta,
                device.source_mass,
                eta,
                target_log_budget,
                sources,
                targets,
                source_active_blocks,
                source_evaluated_pairs,
            )
        else
            exact_launch!(
                alpha,
                device.source_coordinates,
                device.target_coordinates,
                alpha,
                beta,
                device.source_mass,
                eta,
                sources,
                targets,
                Val(true),
            )
        end
    end
    function column_update!(eta)
        if truncated_iteration[]
            truncated_column_updates[] += 1
            refresh!(source_leaf_maxima, source_coarse_maxima, alpha, source_blocks, sources)
            truncated_launch!(
                beta,
                device.target_coordinates,
                target_blocks,
                device.source_coordinates,
                source_blocks,
                source_leaf_maxima,
                source_coarse_maxima,
                beta,
                alpha,
                device.target_mass,
                eta,
                source_log_budget,
                targets,
                sources,
                target_active_blocks,
                target_evaluated_pairs,
            )
        else
            exact_launch!(
                beta,
                device.target_coordinates,
                device.source_coordinates,
                beta,
                alpha,
                device.target_mass,
                eta,
                targets,
                sources,
                Val(true),
            )
        end
    end
    function row_marginals!(eta)
        exact_row_audits[] += 1
        return exact_launch!(
            row_sums,
            device.source_coordinates,
            device.target_coordinates,
            alpha,
            beta,
            device.source_mass,
            eta,
            sources,
            targets,
            Val(false),
        )
    end
    function column_marginals!(eta)
        exact_column_audits[] += 1
        return exact_launch!(
            column_sums,
            device.target_coordinates,
            device.source_coordinates,
            beta,
            alpha,
            device.target_mass,
            eta,
            targets,
            sources,
            Val(false),
        )
    end
    diagnostics = _run_sinkhorn(
        exact.source_mass,
        exact.target_mass,
        backend,
        alpha,
        beta,
        row_sums,
        column_sums,
        row_update!,
        column_update!,
        row_marginals!,
        column_marginals!;
        kwargs...,
    )
    host_source_blocks = _copy_to_host!(
        backend, Vector{UInt64}(undef, sources), source_active_blocks,
    )
    host_source_pairs = _copy_to_host!(
        backend, Vector{UInt64}(undef, sources), source_evaluated_pairs,
    )
    host_target_blocks = _copy_to_host!(
        backend, Vector{UInt64}(undef, targets), target_active_blocks,
    )
    host_target_pairs = _copy_to_host!(
        backend, Vector{UInt64}(undef, targets), target_evaluated_pairs,
    )
    active_blocks = sum(UInt64, host_source_blocks) + sum(UInt64, host_target_blocks)
    evaluated_pairs = sum(UInt64, host_source_pairs) + sum(UInt64, host_target_pairs)
    possible_blocks = UInt64(truncated_row_updates[]) * UInt64(sources) *
                      UInt64(length(problem.target_blocks.leaf.minimum_x)) +
                      UInt64(truncated_column_updates[]) * UInt64(targets) *
                      UInt64(length(problem.source_blocks.leaf.minimum_x))
    possible_pairs = UInt64(truncated_row_updates[] + truncated_column_updates[]) *
                     UInt64(sources) * UInt64(targets)
    exact_update_half_steps = 2 * diagnostics.iterations -
                              truncated_row_updates[] - truncated_column_updates[]
    exact_pair_evaluations = UInt64(
        exact_update_half_steps + exact_row_audits[] + exact_column_audits[],
    ) * UInt64(sources) * UInt64(targets)
    witness_pair_upper_bound = UInt64(truncated_row_updates[]) * UInt64(sources) *
                               UInt64(min(TRUNCATION_BLOCK_SIZE, targets)) +
                               UInt64(truncated_column_updates[]) * UInt64(targets) *
                               UInt64(min(TRUNCATION_BLOCK_SIZE, sources))
    return merge(diagnostics, (;
        truncation=(;
            active_blocks,
            possible_blocks,
            evaluated_pairs,
            possible_pairs,
            exact_pair_evaluations,
            witness_pair_upper_bound,
            pair_evaluation_upper_bound=exact_pair_evaluations + evaluated_pairs +
                                        witness_pair_upper_bound,
            row_updates=truncated_row_updates[],
            column_updates=truncated_column_updates[],
            row_audits=exact_row_audits[],
            column_audits=exact_column_audits[],
        ),
    ))
end
