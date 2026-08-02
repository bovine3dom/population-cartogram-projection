function _minimum_step(values)
    sorted = sort!(unique(Float64.(values)))
    return length(sorted) > 1 ? minimum(diff(sorted)) : 1.0
end

function _scale_to_cartogram(values, cartogram_values)
    source_min, source_max = extrema(values)
    target_min, target_max = extrema(cartogram_values)
    source_min == source_max && return fill((target_min + target_max) / 2, length(values))
    source_midpoint = source_min / 2 + source_max / 2
    source_halfspan = source_max / 2 - source_min / 2
    target_midpoint = target_min / 2 + target_max / 2
    target_halfspan = target_max / 2 - target_min / 2
    return target_midpoint .+
           ((values .- source_midpoint) ./ source_halfspan) .* target_halfspan
end

function _normalized_axis(values)
    converted = _coordinate_value.(values)
    scale = maximum(abs, converted)
    return scale == 0 ? converted : converted ./ scale
end

struct MatrixFreeProblem
    source_x_hi::Vector{Float32}
    source_x_lo::Vector{Float32}
    source_y_hi::Vector{Float32}
    source_y_lo::Vector{Float32}
    target_x_hi::Vector{Float32}
    target_x_lo::Vector{Float32}
    target_y_hi::Vector{Float32}
    target_y_lo::Vector{Float32}
    inverse_distance_scale::Float32
    source_mass::Vector{Float32}
    target_mass::Vector{Float32}
end

@inline function _squared_distance(
    source_x_hi,
    source_x_lo,
    source_y_hi,
    source_y_lo,
    target_x_hi,
    target_x_lo,
    target_y_hi,
    target_y_lo,
)
    dx = (source_x_hi - target_x_hi) + (source_x_lo - target_x_lo)
    dy = (source_y_hi - target_y_hi) + (source_y_lo - target_y_lo)
    return muladd(dx, dx, dy * dy)
end

@inline function _matrix_free_cost(
    source_x_hi,
    source_x_lo,
    source_y_hi,
    source_y_lo,
    target_x_hi,
    target_x_lo,
    target_y_hi,
    target_y_lo,
    inverse_scale,
)
    distance = _squared_distance(
        source_x_hi,
        source_x_lo,
        source_y_hi,
        source_y_lo,
        target_x_hi,
        target_x_lo,
        target_y_hi,
        target_y_lo,
    )
    return min(distance * inverse_scale, 1.0f0)
end

@inline function _cost(problem::MatrixFreeProblem, source, target)
    return _matrix_free_cost(
        problem.source_x_hi[source],
        problem.source_x_lo[source],
        problem.source_y_hi[source],
        problem.source_y_lo[source],
        problem.target_x_hi[target],
        problem.target_x_lo[target],
        problem.target_y_hi[target],
        problem.target_y_lo[target],
        problem.inverse_distance_scale,
    )
end

function _maximum_squared_distance(
    source_x_hi,
    source_x_lo,
    source_y_hi,
    source_y_lo,
    target_x_hi,
    target_x_lo,
    target_y_hi,
    target_y_lo,
)
    maximum_distance = 0.0f0
    @inbounds for source in eachindex(source_x_hi)
        maximum_distance = max(
            maximum_distance,
            _squared_distance(
                source_x_hi[source],
                source_x_lo[source],
                source_y_hi[source],
                source_y_lo[source],
                target_x_hi,
                target_x_lo,
                target_y_hi,
                target_y_lo,
            ),
        )
    end
    return maximum_distance
end

function _split_coordinates(values, origin, step, distance_bound)
    if distance_bound == 0
        return zeros(Float32, length(values)), zeros(Float32, length(values))
    end
    high = Vector{Float32}(undef, length(values))
    low = similar(high)
    @inbounds for index in eachindex(values)
        coordinate = (values[index] - origin) / step / distance_bound
        high[index] = Float32(coordinate)
        low[index] = Float32(coordinate - Float64(high[index]))
    end
    return high, low
end

function _prepare_matrix_free_problem(
    source_x,
    source_y,
    target_x,
    target_y,
    step_x,
    step_y,
    distance_bound,
    source_mass,
    target_mass,
)
    origin_x = minimum(target_x)
    origin_y = minimum(target_y)
    source_x_hi, source_x_lo = _split_coordinates(
        source_x, origin_x, step_x, distance_bound,
    )
    source_y_hi, source_y_lo = _split_coordinates(
        source_y, origin_y, step_y, distance_bound,
    )
    target_x_hi, target_x_lo = _split_coordinates(
        target_x, origin_x, step_x, distance_bound,
    )
    target_y_hi, target_y_lo = _split_coordinates(
        target_y, origin_y, step_y, distance_bound,
    )
    target_maxima = zeros(Float32, length(target_x))
    Threads.@threads for target in eachindex(target_x)
        target_maxima[target] = _maximum_squared_distance(
            source_x_hi,
            source_x_lo,
            source_y_hi,
            source_y_lo,
            target_x_hi[target],
            target_x_lo[target],
            target_y_hi[target],
            target_y_lo[target],
        )
    end
    distance_scale = maximum(target_maxima)
    inverse_distance_scale = distance_scale > 0 ? inv(distance_scale) : 0.0f0
    return MatrixFreeProblem(
        source_x_hi,
        source_x_lo,
        source_y_hi,
        source_y_lo,
        target_x_hi,
        target_x_lo,
        target_y_hi,
        target_y_lo,
        inverse_distance_scale,
        source_mass,
        target_mass,
    )
end

function _masses(cartogram, sources)
    value_scale = maximum(Float64.(sources.value))
    source_mass = Float32[Float64(value) / value_scale for value in sources.value]
    all(value -> isfinite(value) && value > 0, source_mass) || throw(ArgumentError(
        "source values have too much dynamic range for the Float32 solver",
    ))
    source_mass ./= sum(Float64, source_mass)
    all(>(0), source_mass) || throw(ArgumentError(
        "source values have too much dynamic range for the Float32 solver",
    ))
    target_mass = fill(inv(Float32(nrow(cartogram))), nrow(cartogram))
    return source_mass, target_mass
end

function _prepare_problem(cartogram, sources)
    target_x = _normalized_axis(cartogram.x)
    target_y = _normalized_axis(cartogram.y)
    source_x = _scale_to_cartogram(Float64.(sources.x), target_x)
    source_y = _scale_to_cartogram(-Float64.(sources.y), target_y)
    step_x = _minimum_step(target_x)
    step_y = _minimum_step(target_y)
    span_x = (maximum(target_x) - minimum(target_x)) / step_x
    span_y = (maximum(target_y) - minimum(target_y)) / step_y
    distance_bound = hypot(span_x, span_y)
    all(isfinite, (step_x, step_y, span_x, span_y, distance_bound)) || throw(ArgumentError(
        "cartogram coordinate spacing is too small for its extent",
    ))
    source_mass, target_mass = _masses(cartogram, sources)

    return _prepare_matrix_free_problem(
        source_x,
        source_y,
        target_x,
        target_y,
        step_x,
        step_y,
        distance_bound,
        source_mass,
        target_mass,
    )
end
