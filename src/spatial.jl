function _minimum_step(values)
    sorted = sort!(unique(Float64.(values)))
    return length(sorted) > 1 ? minimum(diff(sorted)) : 1.0
end

function _scale_to_cartogram(values, cartogram_values)
    source_min, source_max = extrema(values)
    target_min, target_max = extrema(cartogram_values)
    source_min == source_max && return fill((target_min + target_max) / 2, length(values))
    return target_min .+ (values .- source_min) .*
                         ((target_max - target_min) / (source_max - source_min))
end


function _normalized_axis(values)
    converted = _coordinate_value.(values)
    scale = maximum(abs, converted)
    return scale == 0 ? converted : converted ./ scale
end

function _prepare_problem(cartogram, sources; cost_power)
    !(cost_power isa Bool) && isfinite(cost_power) && cost_power > 0 ||
        throw(ArgumentError("cost_power must be finite and positive"))
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

    cost = Matrix{Float32}(undef, nrow(sources), nrow(cartogram))
    Threads.@threads for target in 1:nrow(cartogram)
        @inbounds for source in 1:nrow(sources)
            if distance_bound == 0
                cost[source, target] = 0
            else
                dx = (source_x[source] - target_x[target]) / step_x / distance_bound
                dy = (source_y[source] - target_y[target]) / step_y / distance_bound
                cost[source, target] = Float32(hypot(dx, dy))
            end
        end
    end
    distance_scale = maximum(cost)
    distance_scale > 0 && (cost .= (cost ./ distance_scale) .^ cost_power)

    value_scale = maximum(Float64.(sources.value))
    source_mass = Float32[Float64(value) / value_scale for value in sources.value]
    all(value -> isfinite(value) && value > 0, source_mass) || throw(ArgumentError(
        "source values have too much dynamic range for the Float32 solver",
    ))
    source_mass ./= sum(source_mass)
    target_mass = fill(inv(Float32(nrow(cartogram))), nrow(cartogram))
    target_mass .*= sum(source_mass) / sum(target_mass)
    target_mass[argmax(target_mass)] += sum(source_mass) - sum(target_mass)
    return (; cost, source_mass, target_mass)
end
