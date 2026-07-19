module PopulationCartogramProjectionH3Ext

using DataFrames
import H3
import PopulationCartogramProjection as PCP

const API = H3.API
const H3Index = API.H3Index

function h3_result(value, operation)
    value isa API.H3ErrorCode && throw(ArgumentError(
        "$operation failed: $(API.describeH3Error(value))",
    ))
    return value
end

function h3_indexes(values)
    any(ismissing, values) && throw(ArgumentError("H3 id cannot be missing"))
    all(value -> value isa Integer && !(value isa Bool), values) ||
        throw(ArgumentError("H3 id must contain integers"))
    all(value -> 0 <= value <= typemax(UInt64), values) ||
        throw(ArgumentError("H3 id must be representable as UInt64"))
    indexes = UInt64.(values)
    all(API.isValidCell, indexes) || throw(ArgumentError("H3 id must contain valid cells"))
    return indexes
end

function PCP.canonicalize_h3_sources(
    table::AbstractDataFrame;
    id=:h3,
    population=:population,
    country_code,
    resolution=nothing,
)
    nrow(table) > 0 || throw(ArgumentError("H3 source table is empty"))
    id_column = PCP._source_column(table, id, "id")
    population_column = PCP._source_column(table, population, "population")
    id_column != population_column || throw(ArgumentError(
        "H3 id and population must use distinct input columns",
    ))
    indexes = h3_indexes(table[!, id_column])
    raw_populations = table[!, population_column]
    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && value > 0, raw_populations) ||
        throw(ArgumentError("H3 population must contain finite positive numbers"))
    populations = Float64.(raw_populations)
    all(isfinite, populations) || throw(ArgumentError(
        "H3 population must be representable as Float64",
    ))
    input_resolutions = Int.(API.getResolution.(indexes))
    target_resolution = if isnothing(resolution)
        all(==(first(input_resolutions)), input_resolutions) ||
            throw(ArgumentError("H3 cells have mixed resolutions; supply resolution to aggregate"))
        first(input_resolutions)
    else
        resolution isa Integer && !(resolution isa Bool) ||
            throw(ArgumentError("resolution must be an integer"))
        0 <= resolution <= minimum(input_resolutions) || throw(ArgumentError(
            "resolution must be between zero and the minimum input resolution",
        ))
        Int(resolution)
    end
    parents = UInt64[
        h3_result(API.cellToParent(index, target_resolution), "cellToParent")
        for index in indexes
    ]
    countries = if country_code isa Integer && !(country_code isa Bool)
        fill(country_code, nrow(table))
    else
        country_column = PCP._source_column(table, country_code, "country_code")
        allunique((id_column, population_column, country_column)) || throw(ArgumentError(
            "H3 id, population, and country_code must use distinct input columns",
        ))
        copy(table[!, country_column])
    end
    grouped = combine(
        groupby(
            DataFrame(id=parents, population=populations, country_code=countries),
            [:country_code, :id];
            sort=false,
        ),
        :population => sum => :population,
    )
    centres = [h3_result(API.cellToLatLng(index), "cellToLatLng") for index in grouped.id]
    grouped.x = rad2deg.([centre.lng for centre in centres])
    grouped.y = rad2deg.([centre.lat for centre in centres])
    select!(grouped, :id, :population, :x, :y, :country_code)
    PCP.validate_sources(grouped)
    return grouped
end

end
