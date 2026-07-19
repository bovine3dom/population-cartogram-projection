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
    targets = copy(grid[target_mask, :])
    value in propertynames(targets) && throw(ArgumentError(
        "value column $value conflicts with a target-grid column",
    ))
    intensive && :projected_population in propertynames(targets) &&
        throw(ArgumentError("target grid cannot contain projected_population"))
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

"""
    dominant_source_assignment(mapping, sources, [grid])

Derive one source identifier per target cell by maximizing transported
population (`population * source_share`). The fractional mapping remains the
authoritative result. Empty cells receive a missing `id`; `transport_share` is
the dominant contribution's share of retained transport mass in that cell.
"""
function dominant_source_assignment(
    mapping::AbstractDataFrame,
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid(),
)
    validate_sources(sources)
    values = select(sources, :id, :country_code)
    population_column = gensym(:population)
    values[!, population_column] = copy(sources.population)
    inputs = _projection_inputs(mapping, values, grid, population_column; intensive=false)
    output_columns = (:id, :transport_mass, :cell_transport_mass, :transport_share)
    conflicts = filter(column -> column in propertynames(inputs.targets), output_columns)
    isempty(conflicts) || throw(ArgumentError(
        "target grid contains assignment output column(s): $(join(string.(conflicts), ", "))",
    ))

    populations = Dict(
        (country, id) => Float64(population)
        for (country, id, population) in
            zip(sources.country_code, sources.id, sources.population)
    )
    best_ids = Dict{Any,Any}()
    best_masses = Dict{Any,Float64}()
    best_source_rows = Dict{Any,Int}()
    cell_masses = Dict{Any,Float64}()
    source_rows = Dict(
        (country, id) => row
        for (row, (country, id)) in enumerate(zip(sources.country_code, sources.id))
    )
    for (country, id, cell, share) in zip(
        mapping.country_code,
        mapping.id,
        mapping.cell_id,
        mapping.source_share,
    )
        key = (country, id)
        mass = populations[key] * Float64(share)
        cell_mass = get(cell_masses, cell, 0.0) + mass
        isfinite(cell_mass) || throw(ArgumentError(
            "transport mass cannot be represented as Float64",
        ))
        cell_masses[cell] = cell_mass
        previous_mass = get(best_masses, cell, -Inf)
        source_row = source_rows[key]
        wins_tie = mass == previous_mass &&
                   source_row < get(best_source_rows, cell, typemax(Int))
        if mass > 0 && (mass > previous_mass || wins_tie)
            best_ids[cell] = id
            best_masses[cell] = mass
            best_source_rows[cell] = source_row
        end
    end

    cells = copy(inputs.targets)
    id_type = Union{Missing,eltype(sources.id)}
    ids = Vector{id_type}(undef, nrow(cells))
    transport_mass = Vector{Float64}(undef, nrow(cells))
    cell_transport_mass = Vector{Float64}(undef, nrow(cells))
    transport_share = Vector{Union{Missing,Float64}}(undef, nrow(cells))
    for (row, cell) in enumerate(cells.cell_id)
        total = get(cell_masses, cell, 0.0)
        dominant = get(best_masses, cell, 0.0)
        ids[row] = get(best_ids, cell, missing)
        transport_mass[row] = dominant
        cell_transport_mass[row] = total
        transport_share[row] = total == 0 ? missing : dominant / total
    end
    cells.id = ids
    cells.transport_mass = transport_mass
    cells.cell_transport_mass = cell_transport_mass
    cells.transport_share = transport_share
    return cells
end

"""
    place_source_labels(mapping, labels, [grid]; label=:name)

Place optional labels that have already been associated with source IDs. For
each source, calculate the `source_share`-weighted cartogram centre and select
its nearest contributed target cell. Returns a complete labeled `cells` table
and one row per input label in `placements`. This is a post-fit annotation step;
it does not affect transport fitting or projection.
"""
function place_source_labels(
    mapping::AbstractDataFrame,
    labels::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    label=:name,
)
    _require_columns(mapping, MAPPING_COLUMNS, "mapping")
    label_column = _source_column(labels, label, "label")
    label_column in (:id, :country_code) &&
        throw(ArgumentError("label must differ from id and country_code"))
    _require_columns(labels, (:id, :country_code), "label table")
    label_values = labels[!, label_column]
    all(
        value -> ismissing(value) || isnothing(value) ||
                 value isa AbstractString,
        label_values,
    ) || throw(ArgumentError("label values must be strings, missing, or nothing"))
    active = [
        value isa AbstractString && !isempty(strip(value))
        for value in label_values
    ]
    active_labels = labels[active, :]
    any(ismissing, active_labels.id) && throw(ArgumentError("label id cannot be missing"))
    all(value -> value isa Integer && !(value isa Bool), active_labels.country_code) ||
        throw(ArgumentError("label country_code must contain integers"))

    mapping_sources = unique(select(mapping, :id, :country_code))
    validation_column = gensym(:label)
    mapping_sources[!, validation_column] = ones(nrow(mapping_sources))
    inputs = _projection_inputs(
        mapping,
        mapping_sources,
        grid,
        validation_column;
        intensive=false,
    )
    mapping_keys = Set(zip(mapping_sources.country_code, mapping_sources.id))
    label_keys = collect(zip(active_labels.country_code, active_labels.id))
    all(key -> key in mapping_keys, label_keys) || throw(ArgumentError(
        "every label must match a (country_code, id) source in the mapping",
    ))
    any(column -> column in propertynames(labels), (:cell_id, :grid_x, :grid_y)) &&
        throw(ArgumentError("label table cannot contain cell_id, grid_x, or grid_y"))
    :label in propertynames(inputs.targets) &&
        throw(ArgumentError("target grid cannot contain label"))

    wanted_keys = Set(label_keys)
    coordinates = Dict(
        cell => (Float64(x), Float64(y))
        for (cell, x, y) in
            zip(inputs.targets.cell_id, inputs.targets.grid_x, inputs.targets.grid_y)
    )
    target_rows = Dict(cell => row for (row, cell) in enumerate(inputs.targets.cell_id))
    total_share = Dict{Any,Float64}()
    weighted_x = Dict{Any,Float64}()
    weighted_y = Dict{Any,Float64}()
    source_cells = Dict{Any,Vector{Any}}()
    for (country, id, cell, share) in zip(
        mapping.country_code,
        mapping.id,
        mapping.cell_id,
        mapping.source_share,
    )
        key = (country, id)
        key in wanted_keys || continue
        x, y = coordinates[cell]
        weight = Float64(share)
        weight > 0 || continue
        total_share[key] = get(total_share, key, 0.0) + weight
        weighted_x[key] = get(weighted_x, key, 0.0) + weight * x
        weighted_y[key] = get(weighted_y, key, 0.0) + weight * y
        push!(get!(source_cells, key, Any[]), cell)
    end

    source_targets = Dict{Any,Any}()
    for key in wanted_keys
        retained = get(total_share, key, 0.0)
        retained > 0 || throw(ArgumentError("every labeled source must retain positive share"))
        centre_x = weighted_x[key] / retained
        centre_y = weighted_y[key] / retained
        best_cell = nothing
        best_score = (Inf, typemax(Int))
        for cell in source_cells[key]
            x, y = coordinates[cell]
            score = (abs2(x - centre_x) + abs2(y - centre_y), target_rows[cell])
            if score < best_score
                best_cell = cell
                best_score = score
            end
        end
        source_targets[key] = best_cell
    end

    placements = copy(active_labels)
    placements.cell_id = [source_targets[key] for key in label_keys]
    placements.grid_x = [coordinates[cell][1] for cell in placements.cell_id]
    placements.grid_y = [coordinates[cell][2] for cell in placements.cell_id]
    labels_by_cell = Dict{Any,Vector{String}}()
    for (cell, value) in zip(placements.cell_id, placements[!, label_column])
        push!(get!(labels_by_cell, cell, String[]), String(value))
    end

    cells = copy(inputs.targets)
    cells.label = Union{Missing,String}[
        haskey(labels_by_cell, cell) ? join(unique(labels_by_cell[cell]), ", ") : missing
        for cell in cells.cell_id
    ]
    return (; cells, placements)
end
