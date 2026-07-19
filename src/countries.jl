function _crosswalk(crosswalk, input_codes, target_codes)
    crosswalk isa AbstractDict || throw(ArgumentError("crosswalk must be a dictionary"))
    result = Dict{Int,Int}()
    for (source, target) in pairs(crosswalk)
        source isa Integer && !(source isa Bool) &&
            target isa Integer && !(target isa Bool) || throw(ArgumentError(
                "crosswalk keys and values must be integer country codes",
            ))
        Int(source) in input_codes || throw(ArgumentError("crosswalk contains unused source code $source"))
        Int(source) in target_codes && throw(ArgumentError(
            "crosswalk cannot override directly supported country code $source",
        ))
        Int(target) in target_codes || throw(ArgumentError(
            "crosswalk target country code $target is absent from the target grid",
        ))
        result[Int(source)] = Int(target)
    end
    return result
end

"""
    reconcile_countries(sources, [grid]; crosswalk=Dict())

Reconcile integer source country codes to target-grid codes using only the
explicit crosswalk supplied by the caller. Unsupported countries are reported
as skipped. Many-to-one reconciliation is rejected.
"""
function reconcile_countries(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    crosswalk=Dict{Int,Int}(),
)
    _require_columns(sources, SOURCE_COLUMNS, "source table")
    nrow(sources) > 0 || throw(ArgumentError("source table is empty"))
    all(value -> value isa Integer && !(value isa Bool), sources.country_code) ||
        throw(ArgumentError("source country_code must contain integers"))
    :input_country_code in propertynames(sources) && throw(ArgumentError(
        "source table already contains the reserved input_country_code column",
    ))
    _validate_grid(grid)
    input_codes = sort!(unique(Int.(sources.country_code)))
    target_codes = Set(Int.(grid.country_code))
    map = _crosswalk(crosswalk, Set(input_codes), target_codes)
    effective = Dict(
        code => code in target_codes ? code : get(map, code, nothing)
        for code in input_codes
    )
    supported_outputs = filter(!isnothing, collect(values(effective)))
    allunique(supported_outputs) || throw(ArgumentError(
        "multiple input countries cannot map to the same target country",
    ))

    status_rows = NamedTuple[]
    retained_parts = DataFrame[]
    for input_code in input_codes
        rows = findall(==(input_code), sources.country_code)
        target_code = effective[input_code]
        source_population = try
            sum(Float64.(sources.population[rows]))
        catch
            NaN
        end
        if isnothing(target_code)
            push!(status_rows, (;
                input_country_code=input_code,
                country_code=missing,
                status=:skipped,
                source_rows=length(rows),
                source_population,
                target_cells=0,
                error_type=missing,
                message="no matching target country and no explicit crosswalk",
            ))
            continue
        end
        part = copy(sources[rows, :])
        part.input_country_code = fill(input_code, nrow(part))
        part.country_code .= target_code
        push!(retained_parts, part)
        push!(status_rows, (;
            input_country_code=input_code,
            country_code=target_code,
            status=target_code == input_code ? :included : :remapped,
            source_rows=length(rows),
            source_population,
            target_cells=count(==(target_code), grid.country_code),
            error_type=missing,
            message="",
        ))
    end
    reconciled = isempty(retained_parts) ? sources[1:0, :] : reduce(vcat, retained_parts)
    if isempty(retained_parts)
        reconciled.input_country_code = Int[]
    end
    statuses = DataFrame(status_rows)
    retained_population = sum(
        (row.source_population for row in status_rows if row.status != :skipped && isfinite(row.source_population));
        init=0.0,
    )
    metadata = (;
        schema_version=1,
        input_countries=length(input_codes),
        retained_countries=nrow(statuses) - count(==(:skipped), statuses.status),
        skipped_countries=count(==(:skipped), statuses.status),
        input_sources=nrow(sources),
        retained_sources=nrow(reconciled),
        skipped_sources=nrow(sources) - nrow(reconciled),
        input_population=try sum(Float64.(sources.population)) catch; NaN end,
        retained_population,
        crosswalk=map,
    )
    return (; sources=reconciled, statuses, metadata)
end

function _empty_mapping(sources, grid)
    return DataFrame(
        id=eltype(sources.id)[],
        country_code=Int[],
        cell_id=eltype(grid.cell_id)[],
        source_share=Float64[],
    )
end

function _empty_retention(sources)
    return DataFrame(
        id=eltype(sources.id)[],
        country_code=Int[],
        neighbors=Int[],
        retained_share=Float64[],
        dropped_share=Float64[],
        cumulative_achieved=Bool[],
        truncation_reason=Symbol[],
    )
end

"""
    fit_mapping_countries(sources, [grid]; backend, crosswalk=Dict(),
                          allow_partial=false, kwargs...)

Reconcile and fit each country independently with `fit_mapping_auto`. The
returned mapping and retained sources are directly usable by projection
helpers. Skipped or failed countries raise `IncompleteCountryFitError` unless
`allow_partial=true`; an all-failed request always raises.
"""
function fit_mapping_countries(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    backend::Symbol,
    crosswalk=Dict{Int,Int}(),
    allow_partial::Bool=false,
    kwargs...,
)
    _validate_backend(backend)
    reconciled = reconcile_countries(sources, grid; crosswalk)
    statuses = copy(reconciled.statuses)
    statuses.error_type = Union{Missing,String}[value for value in statuses.error_type]
    statuses.message = Union{Missing,String}[value for value in statuses.message]
    statuses.selected_eta = Union{Missing,Float64}[missing for _ in 1:nrow(statuses)]
    statuses.mapping_rows = Union{Missing,Int}[missing for _ in 1:nrow(statuses)]
    statuses.retained_mass_share = Union{Missing,Float64}[missing for _ in 1:nrow(statuses)]
    mapping_parts = DataFrame[]
    retention_parts = DataFrame[]
    source_parts = DataFrame[]
    country_fits = Dict{Int,Any}()

    for row_index in 1:nrow(statuses)
        statuses.status[row_index] == :skipped && continue
        input_code = statuses.input_country_code[row_index]
        target_code = statuses.country_code[row_index]
        part = filter(:input_country_code => ==(input_code), reconciled.sources)
        try
            fitted = fit_mapping_auto(part, grid; backend, kwargs...)
            country_fits[target_code] = fitted
            push!(mapping_parts, fitted.mapping)
            push!(retention_parts, fitted.source_retention)
            push!(source_parts, part)
            statuses.selected_eta[row_index] = fitted.metadata.selected_eta
            statuses.mapping_rows[row_index] = nrow(fitted.mapping)
            statuses.retained_mass_share[row_index] = fitted.metadata.retained_mass_share
        catch error
            error isa Union{ArgumentError,MappingFitError} || rethrow()
            statuses.status[row_index] = :failed
            statuses.error_type[row_index] = string(nameof(typeof(error)))
            statuses.message[row_index] = sprint(showerror, error)
        end
    end

    combined_mapping = isempty(mapping_parts) ? _empty_mapping(sources, grid) : reduce(vcat, mapping_parts)
    combined_retention = isempty(retention_parts) ? _empty_retention(sources) : reduce(vcat, retention_parts)
    successful_sources = isempty(source_parts) ? reconciled.sources[1:0, :] : reduce(vcat, source_parts)
    successful_population = isempty(source_parts) ? 0.0 : sum(Float64.(successful_sources.population))
    successful_count = length(source_parts)
    metadata = (;
        schema_version=1,
        fit_mode=:countries,
        backend,
        input_countries=nrow(statuses),
        successful_countries=successful_count,
        skipped_countries=count(==(:skipped), statuses.status),
        failed_countries=count(==(:failed), statuses.status),
        input_sources=nrow(sources),
        successful_sources=nrow(successful_sources),
        input_population=try sum(Float64.(sources.population)) catch; NaN end,
        successful_population,
        mapping_rows=nrow(combined_mapping),
        reconciliation=reconciled.metadata,
        country_metadata=Dict(code => fit.metadata for (code, fit) in country_fits),
    )
    result = MultiCountryFit(
        combined_mapping,
        combined_retention,
        successful_sources,
        statuses,
        country_fits,
        metadata,
    )
    incomplete = any(in((:skipped, :failed)), statuses.status)
    (successful_count == 0 || (incomplete && !allow_partial)) &&
        throw(IncompleteCountryFitError(result))
    return result
end
