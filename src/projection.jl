const MAPPING_COLUMNS = (:id, :country_code, :cell_id, :source_share)
const PROJECTION_SHARE_TOLERANCE = 1e-6

function _projection_inputs(
    mapping::AbstractDataFrame,
    values::AbstractDataFrame,
    grid::AbstractDataFrame,
    value::Symbol;
    intensive::Bool,
)
    _require_columns(mapping, MAPPING_COLUMNS, "mapping")
    reserved = intensive ? (:id, :country_code, :cell_id, :grid_x, :grid_y, :population, :projected_population) :
                           (:id, :country_code, :cell_id, :grid_x, :grid_y)
    value ∉ reserved || throw(ArgumentError("value column $value conflicts with a projection output column"))
    required_values = intensive ? (:id, :country_code, :population, value) :
                                  (:id, :country_code, value)
    _require_columns(values, required_values, "value table")
    _validate_grid(grid)
    nrow(mapping) > 0 || throw(ArgumentError("mapping is empty"))
    nrow(values) > 0 || throw(ArgumentError("value table is empty"))

    any(ismissing, mapping.id) && throw(ArgumentError("mapping id cannot be missing"))
    any(ismissing, mapping.country_code) &&
        throw(ArgumentError("mapping country_code cannot be missing"))
    any(ismissing, mapping.cell_id) && throw(ArgumentError("mapping cell_id cannot be missing"))
    all(entry -> entry isa Integer && !(entry isa Bool), mapping.country_code) ||
        throw(ArgumentError("mapping country_code must contain integers"))
    all(
        share -> share isa Real && !(share isa Bool) && isfinite(share) && 0 <= share <= 1,
        mapping.source_share,
    ) || throw(ArgumentError("mapping source_share must contain finite values in [0, 1]"))

    mapping_rows = Set(zip(mapping.country_code, mapping.id, mapping.cell_id))
    length(mapping_rows) == nrow(mapping) ||
        throw(ArgumentError("(country_code, id, cell_id) must uniquely identify each mapping row"))

    any(ismissing, values.id) && throw(ArgumentError("value table id cannot be missing"))
    any(ismissing, values.country_code) &&
        throw(ArgumentError("value table country_code cannot be missing"))
    all(entry -> entry isa Integer && !(entry isa Bool), values.country_code) ||
        throw(ArgumentError("value table country_code must contain integers"))
    all(
        entry -> entry isa Real && !(entry isa Bool) && isfinite(entry),
        values[!, value],
    ) || throw(ArgumentError("value column $value must contain finite numbers"))
    if intensive
        all(
            population -> population isa Real && !(population isa Bool) &&
                          isfinite(population) && population > 0,
            values.population,
        ) || throw(ArgumentError("value table population must contain finite positive numbers"))
    end

    source_keys = collect(zip(values.country_code, values.id))
    source_key_set = Set(source_keys)
    length(source_key_set) == nrow(values) ||
        throw(ArgumentError("(country_code, id) must uniquely identify each value row"))
    mapping_source_keys = Set(zip(mapping.country_code, mapping.id))
    mapping_source_keys == source_key_set || throw(ArgumentError(
        "mapping and value table must contain the same (country_code, id) source keys",
    ))

    grid_countries = Dict(cell => country for (cell, country) in zip(grid.cell_id, grid.country_code))
    for (country, cell) in zip(mapping.country_code, mapping.cell_id)
        get(grid_countries, cell, nothing) == country || throw(ArgumentError(
            "mapping cell_id=$cell does not belong to country_code=$country in the target grid",
        ))
    end

    retained_by_source = Dict(key => 0.0 for key in source_keys)
    neighbors_by_source = Dict(key => 0 for key in source_keys)
    for (country, id, share) in zip(mapping.country_code, mapping.id, mapping.source_share)
        key = (country, id)
        retained_by_source[key] += Float64(share)
        neighbors_by_source[key] += 1
    end
    raw_retained_shares = [retained_by_source[key] for key in source_keys]
    all(share -> share <= 1 + PROJECTION_SHARE_TOLERANCE, raw_retained_shares) ||
        throw(ArgumentError(
            "mapping source_share sums cannot exceed one per source beyond numerical tolerance",
        ))
    source_retention = DataFrame(
        id=copy(values.id),
        country_code=copy(values.country_code),
        neighbors=[neighbors_by_source[key] for key in source_keys],
        retained_share=raw_retained_shares,
        dropped_share=1 .- raw_retained_shares,
    )

    country_codes = sort!(unique(collect(values.country_code)))
    country_set = Set(country_codes)
    target_mask = [country in country_set for country in grid.country_code]
    targets = select(grid[target_mask, :], GRID_COLUMNS...)
    source_values = Dict(
        key => Float64(values[row, value]) for (row, key) in enumerate(source_keys)
    )
    source_populations = intensive ? Dict(
        key => Float64(values.population[row]) for (row, key) in enumerate(source_keys)
    ) : nothing

    return (;
        targets,
        source_keys,
        source_values,
        source_populations,
        source_retention,
        retained_shares=raw_retained_shares,
        country_codes,
    )
end

function _projection_metadata(inputs, mapping, value, projection)
    return (;
        projection,
        value,
        sources=length(inputs.source_keys),
        country_codes=inputs.country_codes,
        grid_cells=nrow(inputs.targets),
        mapping_rows=nrow(mapping),
        minimum_retained_source_share=minimum(inputs.retained_shares),
        maximum_dropped_source_share=maximum(1 .- inputs.retained_shares),
    )
end

"""
    project_extensive(mapping, values, [grid]; value)

Project a finite source-level extensive quantity onto target cells. Each source
value is distributed using its unchanged `source_share`; sparse dropped share is
reported rather than renormalized. Returns `cells`, `source_retention`, and
`metadata`.
"""
function project_extensive(
    mapping::AbstractDataFrame,
    values::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    value::Symbol,
)
    inputs = _projection_inputs(mapping, values, grid, value; intensive=false)
    projected_by_cell = Dict{Any,Float64}()
    for (country, id, cell, share) in zip(
        mapping.country_code,
        mapping.id,
        mapping.cell_id,
        mapping.source_share,
    )
        contribution = inputs.source_values[(country, id)] * Float64(share)
        projected_by_cell[cell] = get(projected_by_cell, cell, 0.0) + contribution
    end

    cells = copy(inputs.targets)
    cells[!, value] = [get(projected_by_cell, cell, 0.0) for cell in cells.cell_id]
    input_total = sum(Float64.(values[!, value]))
    projected_total = sum(cells[!, value])
    metadata = merge(
        _projection_metadata(inputs, mapping, value, :extensive),
        (; input_total, projected_total, dropped_total=input_total - projected_total),
    )
    return (; cells, source_retention=inputs.source_retention, metadata)
end

"""
    project_intensive(mapping, values, [grid]; value)

Project a finite source-level intensive quantity as a population-weighted mean.
The denominator is `sum(population * source_share)` and is returned as
`projected_population`. Sparse shares are not renormalized. Returns `cells`,
`source_retention`, and `metadata`.
"""
function project_intensive(
    mapping::AbstractDataFrame,
    values::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    value::Symbol,
)
    inputs = _projection_inputs(mapping, values, grid, value; intensive=true)
    population_by_cell = Dict{Any,Float64}()
    numerator_by_cell = Dict{Any,Float64}()
    for (country, id, cell, share) in zip(
        mapping.country_code,
        mapping.id,
        mapping.cell_id,
        mapping.source_share,
    )
        key = (country, id)
        transported_population = inputs.source_populations[key] * Float64(share)
        population_by_cell[cell] = get(population_by_cell, cell, 0.0) + transported_population
        numerator_by_cell[cell] = get(numerator_by_cell, cell, 0.0) +
                                  inputs.source_values[key] * transported_population
    end

    cells = copy(inputs.targets)
    projected_population = [get(population_by_cell, cell, 0.0) for cell in cells.cell_id]
    projected_values = Union{Missing,Float64}[
        population == 0 ? missing : numerator_by_cell[cell] / population
        for (cell, population) in zip(cells.cell_id, projected_population)
    ]
    cells.projected_population = projected_population
    cells[!, value] = projected_values

    input_population = sum(Float64.(values.population))
    total_projected_population = sum(projected_population)
    retained_population_share = total_projected_population / input_population
    metadata = merge(
        _projection_metadata(inputs, mapping, value, :intensive),
        (;
            input_population,
            projected_population=total_projected_population,
            dropped_population=input_population - total_projected_population,
            retained_population_share,
            dropped_population_share=1 - retained_population_share,
            zero_population_cells=count(iszero, projected_population),
        ),
    )
    return (; cells, source_retention=inputs.source_retention, metadata)
end
