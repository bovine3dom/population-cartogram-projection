function _validate_cost_power(cost_power)
    !(cost_power isa Bool) && isfinite(cost_power) && cost_power > 0 ||
        throw(ArgumentError("cost_power must be finite and positive"))
    return nothing
end

function _country_targets(sources, grid)
    validate_sources(sources)
    _validate_grid(grid)
    country_codes = unique(sources.country_code)
    length(country_codes) == 1 ||
        throw(ArgumentError("fit_mapping currently supports one country at a time"))
    country_code = only(country_codes)
    targets = filter(:country_code => ==(country_code), grid)
    nrow(targets) > 0 ||
        throw(ArgumentError("OWID grid has no cells for country_code=$country_code"))
    return targets
end

function _minimum_step(values)
    sorted_values = sort!(unique(Float64.(values)))
    return length(sorted_values) > 1 ? minimum(diff(sorted_values)) : 1.0
end

function _scale_to_grid(values, grid_values)
    source_min, source_max = extrema(values)
    target_min, target_max = extrema(grid_values)
    source_min == source_max && return fill((target_min + target_max) / 2, length(values))
    return target_min .+ (values .- source_min) .*
                         ((target_max - target_min) / (source_max - source_min))
end

function _prepare_spatial_cost(sources, targets; cost_power)
    _validate_cost_power(cost_power)
    longitude = Float64.(sources.x)
    latitude = Float64.(sources.y)
    grid_x = Float64.(targets.grid_x)
    grid_y = Float64.(targets.grid_y)
    source_x = _scale_to_grid(longitude, grid_x)
    source_y = _scale_to_grid(-latitude, grid_y)
    step_x = _minimum_step(grid_x)
    step_y = _minimum_step(grid_y)

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

    distance_scale = maximum(cost)
    if distance_scale > 0
        cost .= (cost ./ distance_scale) .^ cost_power
    end
    metadata = (
        method="source_extrema",
        longitude_bounds=extrema(longitude),
        latitude_bounds=extrema(latitude),
        grid_x_bounds=extrema(grid_x),
        grid_y_bounds=extrema(grid_y),
        grid_step=(step_x, step_y),
        distance_scale=Float64(distance_scale),
        cost_power=Float64(cost_power),
    )
    return (; cost, metadata)
end

function _prepare_problem(
    sources::AbstractDataFrame,
    targets::AbstractDataFrame;
    cost_power::Real=2,
)
    spatial = _prepare_spatial_cost(sources, targets; cost_power)
    population_scale = maximum(sources.population)
    source_mass = Float32[value / population_scale for value in sources.population]
    all(isfinite, source_mass) ||
        throw(ArgumentError("source population is too large to represent"))
    source_mass ./= sum(source_mass)
    target_mass = fill(inv(Float32(nrow(targets))), nrow(targets))
    target_mass ./= sum(target_mass)
    return (;
        spatial.cost,
        source_mass,
        target_mass,
        spatial_metadata=spatial.metadata,
    )
end
