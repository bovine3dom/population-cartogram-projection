#!/usr/bin/env julia

module EuropeExample

using Arrow
using CSV
using CUDA
using DataFrames
using H3
using PopulationCartogramProjection

include(joinpath(@__DIR__, "..", "common.jl"))

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const COUNTRIES_PATH = joinpath(@__DIR__, "countries.csv")
const POPULATION_PATH = joinpath(
    ROOT, "make-lookup-table", "population-data", "kontur_population_20231101.arrow",
)
const BOUNDARY_PATH = joinpath(
    ROOT,
    "make-lookup-table",
    "population-data",
    "country-boundaries",
    "ne_10m_admin_0_map_units.arrow",
)
const CITIES_PATH = joinpath(
    ROOT, "make-lookup-table", "population-data", "tiny-cities.csv",
)
const DEFAULT_OUTPUT_DIR = joinpath(ROOT, "output", "europe")
const DEFAULT_SOURCE_CACHE = joinpath(DEFAULT_OUTPUT_DIR, "sources-res6.arrow")
const H3_RESOLUTION = 6

function sql_literal(value::AbstractString)
    any(iscntrl, value) && error("paths cannot contain control characters")
    return "'$(replace(value, '\\' => "\\\\", '\'' => "''"))'"
end

function load_countries(path::AbstractString=COUNTRIES_PATH)
    countries = CSV.read(
        path,
        DataFrame;
        types=Dict(:cartogram_code => Int, :source_code => Int, :name => String),
    )
    nrow(countries) > 0 || error("Europe country list is empty")
    allunique(countries.cartogram_code) || error("cartogram country codes must be unique")
    allunique(countries.source_code) || error("source country codes must be unique")
    return countries
end

function prepare_sources(
    output_path::AbstractString=DEFAULT_SOURCE_CACHE;
    countries=load_countries(),
    resolution::Int=H3_RESOLUTION,
)
    0 <= resolution <= 8 || error("parent H3 resolution must be between 0 and 8")
    isfile(POPULATION_PATH) || error("population input not found at $POPULATION_PATH")
    isfile(BOUNDARY_PATH) || error("boundary input not found at $BOUNDARY_PATH")
    clickhouse = Sys.which("clickhouse")
    isnothing(clickhouse) && error("clickhouse executable not found")
    mkpath(dirname(output_path))
    temporary_path = "$output_path.tmp.$(getpid()).$(time_ns())"
    codes = join(countries.source_code, ", ")
    boundary_audit_query = """
        WITH
            [$codes] AS europe_codes,
            candidate_parents AS
            (
                SELECT DISTINCT h3ToParent(assumeNotNull(h3), $resolution) AS parent
                FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
                WHERE
                    isNotNull(h3) AND
                    isNotNull(ISO_N3_EH) AND
                    h3IsValid(assumeNotNull(h3)) AND
                    toInt32(ISO_N3_EH) IN europe_codes
            ),
            boundaries AS
            (
                SELECT
                    assumeNotNull(h3) AS h3,
                    uniqExact(toInt32(ISO_N3_EH)) AS boundary_codes
                FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
                WHERE
                    isNotNull(h3) AND
                    isNotNull(ISO_N3_EH) AND
                    h3IsValid(assumeNotNull(h3)) AND
                    h3ToParent(assumeNotNull(h3), $resolution) IN
                        (SELECT parent FROM candidate_parents)
                GROUP BY h3
            ),
            population_rows AS
            (
                SELECT
                    assumeNotNull(h3) AS h3,
                    toFloat64(assumeNotNull(population)) AS value
                FROM file($(sql_literal(POPULATION_PATH)), Arrow)
                WHERE
                    isNotNull(h3) AND
                    isNotNull(population) AND
                    h3IsValid(assumeNotNull(h3)) AND
                    h3ToParent(assumeNotNull(h3), $resolution) IN
                        (SELECT parent FROM candidate_parents)
            )
        SELECT
            count(),
            sum(value),
            countIf(boundary_codes = 0),
            sumIf(value, boundary_codes = 0),
            countIf(boundary_codes > 1),
            sumIf(value, boundary_codes > 1),
            count() - uniqExact(h3),
            (
                SELECT countIf(
                    isNull(h3) OR NOT h3IsValid(assumeNotNull(h3)) OR
                    isNull(population) OR
                    NOT isFinite(toFloat64(assumeNotNull(population))) OR
                    assumeNotNull(population) <= 0
                )
                FROM file($(sql_literal(POPULATION_PATH)), Arrow)
            ),
            (
                SELECT countIf(
                    isNull(h3) OR NOT h3IsValid(assumeNotNull(h3)) OR
                    isNull(ISO_N3_EH)
                )
                FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
            )
        FROM population_rows
        LEFT JOIN boundaries USING (h3)
        SETTINGS max_threads = 1
        FORMAT TSV
        """
    query = """
        WITH
            [$codes] AS europe_codes,
            candidate_parents AS
            (
                SELECT DISTINCT h3ToParent(assumeNotNull(h3), $resolution) AS parent
                FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
                WHERE
                    isNotNull(h3) AND
                    isNotNull(ISO_N3_EH) AND
                    h3IsValid(assumeNotNull(h3)) AND
                    toInt32(ISO_N3_EH) IN europe_codes
            ),
            boundaries AS
            (
                SELECT
                    assumeNotNull(h3) AS h3,
                    min(toInt32(ISO_N3_EH)) AS code,
                    uniqExact(toInt32(ISO_N3_EH)) AS code_count
                FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
                WHERE
                    isNotNull(h3) AND
                    isNotNull(ISO_N3_EH) AND
                    h3IsValid(assumeNotNull(h3)) AND
                    h3ToParent(assumeNotNull(h3), $resolution) IN
                        (SELECT parent FROM candidate_parents)
                GROUP BY h3
            ),
            country_rows AS
            (
                SELECT
                    h3ToParent(population.h3, $resolution) AS parent,
                    boundary.code AS code,
                    count() AS code_rows,
                    min(population.row_index) AS first_row,
                    sum(population.population) AS code_population,
                    countIf(boundary.code_count > 1) AS ambiguous_rows,
                    sumIf(population.population, boundary.code_count > 1) AS ambiguous_population
                FROM
                (
                    SELECT
                        assumeNotNull(h3) AS h3,
                        assumeNotNull(population) AS population,
                        rowNumberInAllBlocks() AS row_index
                    FROM file($(sql_literal(POPULATION_PATH)), Arrow)
                    WHERE
                        isNotNull(h3) AND
                        isNotNull(population) AND
                        h3IsValid(assumeNotNull(h3)) AND
                        h3ToParent(assumeNotNull(h3), $resolution) IN
                            (SELECT parent FROM candidate_parents)
                ) AS population
                INNER JOIN boundaries AS boundary USING (h3)
                GROUP BY parent, code
            )
        SELECT
            assumeNotNull(parent) AS id,
            parent_population AS population,
            tupleElement(h3ToGeo(assumeNotNull(parent)), 2) AS x,
            tupleElement(h3ToGeo(assumeNotNull(parent)), 1) AS y,
            toInt64(parent_code) AS country_code,
            ambiguous_rows,
            ambiguous_population
        FROM
        (
            SELECT
                parent,
                sum(code_population) AS parent_population,
                tupleElement(arrayElement(arraySort(
                    item -> (-tupleElement(item, 2), tupleElement(item, 3)),
                    groupArray((code, code_rows, first_row))
                ), 1), 1) AS parent_code,
                sum(ambiguous_rows) AS ambiguous_rows,
                sum(ambiguous_population) AS ambiguous_population
            FROM country_rows
            GROUP BY parent
        )
        WHERE parent_code IN europe_codes
        ORDER BY indexOf(europe_codes, parent_code), id
        INTO OUTFILE $(sql_literal(temporary_path))
        FORMAT Arrow
        SETTINGS max_threads = 1, h3togeo_lon_lat_result_order = 0
        """
    try
        boundary_audit = split(
            strip(read(Cmd([clickhouse, "local", "--query", boundary_audit_query]), String)),
            '\t',
        )
        length(boundary_audit) == 9 || error("unexpected Europe boundary audit output")
        all(iszero, parse.(Int, boundary_audit[8:9])) || error(
            "Europe inputs contain invalid H3 indexes, populations, or country codes",
        )
        parse(Int, boundary_audit[7]) == 0 || error("population input contains duplicate H3 rows")
        parse(Int, boundary_audit[5]) == 0 || error(
            "Europe population has ambiguous country boundaries",
        )
        println(
            "candidate_rows\tcandidate_population\tunmatched_rows\t" *
            "unmatched_population\tambiguous_rows\tambiguous_population",
        )
        println(join(boundary_audit[1:6], '\t'))
        parse(Int, boundary_audit[3]) > 0 && @warn(
            "Unmatched population rows are excluded from the Europe source cache",
            rows=parse(Int, boundary_audit[3]),
            population=parse(Float64, boundary_audit[4]),
        )
        run(Cmd([clickhouse, "local", "--query", query]))
        sources = DataFrame(Arrow.Table(temporary_path))
        validate_sources(sources, countries; resolution)
        mv(temporary_path, output_path; force=true)
    finally
        ispath(temporary_path) && rm(temporary_path; force=true)
    end
    println("Wrote Europe source cache to $output_path")
    return output_path
end

function validate_sources(sources, countries=load_countries(); resolution=H3_RESOLUTION)
    required = (
        :id, :population, :x, :y, :country_code, :ambiguous_rows, :ambiguous_population,
    )
    all(column -> column in propertynames(sources), required) ||
        error("Europe source cache is missing required columns")
    ids = UInt64.(sources.id)
    allunique(ids) || error("Europe source H3 ids must be unique")
    all(H3.API.isValidCell, ids) || error("Europe source cache contains invalid H3 ids")
    all(==(resolution), Int.(H3.API.getResolution.(ids))) ||
        error("Europe source cache has the wrong H3 resolution")
    Set(sources.country_code) == Set(countries.source_code) ||
        error("Europe source cache does not contain exactly the configured countries")
    all(value -> value isa Real && isfinite(value) && value > 0, sources.population) ||
        error("Europe source populations must be finite and positive")
    all(value -> value isa Real && isfinite(value) && -180 <= value <= 180, sources.x) ||
        error("Europe source longitudes are invalid")
    all(value -> value isa Real && isfinite(value) && -90 <= value <= 90, sources.y) ||
        error("Europe source latitudes are invalid")
    centres = H3.API.cellToLatLng.(ids)
    any(value -> value isa H3.API.H3ErrorCode, centres) && error("H3 centroid lookup failed")
    maximum(abs.(Float64.(sources.x) .- [rad2deg(centre.lng) for centre in centres])) <= 1e-9 ||
        error("Europe source longitudes do not match their H3 ids")
    maximum(abs.(Float64.(sources.y) .- [rad2deg(centre.lat) for centre in centres])) <= 1e-9 ||
        error("Europe source latitudes do not match their H3 ids")
    all(iszero, sources.ambiguous_rows) || error(
        "Europe source cache contains populated H3 cells with ambiguous country boundaries",
    )
    all(iszero, sources.ambiguous_population) || error(
        "Europe source cache contains ambiguous population",
    )
    return nothing
end

function load_sources(path::AbstractString=DEFAULT_SOURCE_CACHE; countries=load_countries())
    isfile(path) || prepare_sources(path; countries)
    raw = DataFrame(Arrow.Table(path))
    validate_sources(raw, countries)
    return DataFrame(
        id=UInt64.(raw.id),
        x=Float64.(raw.x),
        y=Float64.(raw.y),
        value=Float64.(raw.population),
        country_code=Int.(raw.country_code),
    )
end

lower_uint32(value::UInt64) = UInt32(value & 0x00000000ffffffff)
upper_uint32(value::UInt64) = UInt32(value >> 32)

function city_names(path::AbstractString=CITIES_PATH; resolution=H3_RESOLUTION, minimum=50_000)
    cities = CSV.read(path, DataFrame)
    filter!(:population => >(minimum), cities)
    sort!(cities, :population; rev=true)
    cells = H3.API.latLngToCell.(
        H3.API.LatLng.(deg2rad.(cities.latitude), deg2rad.(cities.longitude)),
        resolution,
    )
    any(value -> value isa H3.API.H3ErrorCode, cells) && error("city H3 conversion failed")
    cities.id = UInt64.(cells)
    return combine(
        groupby(cities, :id; sort=false),
        :name => (values -> join(unique(values), ", ")) => :name,
    )
end

function assign_labels!(mapping, names)
    name_by_id = Dict(zip(names.id, names.name))
    rows_by_id = Dict{UInt64,Vector{Int}}()
    for row in 1:nrow(mapping)
        haskey(name_by_id, mapping.id[row]) || continue
        push!(get!(rows_by_id, mapping.id[row], Int[]), row)
    end
    mapping.label = Vector{Union{Missing,String}}(missing, nrow(mapping))
    for (id, rows) in rows_by_id
        total = sum(mapping.weight[rows])
        centre_x = sum(mapping.x[rows] .* mapping.weight[rows]) / total
        centre_y = sum(mapping.y[rows] .* mapping.weight[rows]) / total
        selected = rows[argmin(
            (mapping.x[rows] .- centre_x) .^ 2 .+ (mapping.y[rows] .- centre_y) .^ 2,
        )]
        mapping.label[selected] = name_by_id[id]
    end
    return mapping
end

function fit_europe(countries, sources; factor=1, backend=CUDA.CUDABackend())
    source_groups = groupby(sources, :country_code)
    available_codes = Set(unique(sources.country_code))
    results = DataFrame[]
    for (position, country) in enumerate(eachrow(countries))
        country.source_code in available_codes || error(
            "no population sources for $(country.name) ($(country.source_code))",
        )
        selected = DataFrame(source_groups[(country_code=country.source_code,)])
        source_table = select(selected, :id, :x, :y, :value)
        cartogram = load_cartogram(country.cartogram_code; factor)
        println(
            "[$position/$(nrow(countries))] $(country.name): " *
            "$(nrow(source_table)) sources, $(nrow(cartogram)) cells",
        )
        mapping = distribute(
            select(cartogram, :x, :y),
            source_table;
            backend,
        )
        mapping = leftjoin(
            mapping,
            select(source_table, :id, :value => :population);
            on=:id,
            validate=(false, true),
        )
        mapping.code = fill(country.source_code, nrow(mapping))
        push!(results, mapping)
        GC.gc(false)
        backend isa CUDA.CUDABackend && CUDA.reclaim()
    end
    return reduce(vcat, results)
end

function hilo_output(mapping)
    output = select(mapping, :x, :y, :weight, :population, :code, :label, :weight_mean)
    output.index_lower = lower_uint32.(mapping.id)
    output.index_upper = upper_uint32.(mapping.id)
    allowmissing!(output)
    return output
end

function validate_output(output, countries; sources=nothing, factor=nothing)
    nrow(output) > 0 || error("Europe output is empty")
    required = (
        :x, :y, :weight, :population, :code, :label, :weight_mean,
        :index_lower, :index_upper,
    )
    all(column -> column in propertynames(output), required) ||
        error("Europe output is missing required columns")
    Set(output.code) == Set(countries.source_code) ||
        error("Europe output is missing configured countries")
    all(value -> !ismissing(value) && value isa Real && isfinite(value), output.x) ||
        error("Europe output contains invalid x coordinates")
    all(value -> !ismissing(value) && value isa Real && isfinite(value), output.y) ||
        error("Europe output contains invalid y coordinates")
    all(value -> !ismissing(value) && isfinite(value) && 0 < value <= 1, output.weight) ||
        error("Europe output contains invalid source weights")
    all(value -> !ismissing(value) && isfinite(value) && 0 < value <= 1, output.weight_mean) ||
        error("Europe output contains invalid target weights")
    all(value -> !ismissing(value) && isfinite(value) && value > 0, output.population) ||
        error("Europe output contains invalid populations")
    for column in (:index_lower, :index_upper)
        all(
            value -> !ismissing(value) && value isa Integer && !(value isa Bool) &&
                     0 <= value <= typemax(UInt32),
            output[!, column],
        ) || error("Europe output $column values must be UInt32-compatible integers")
    end
    reconstructed = (UInt64.(output.index_upper) .<< 32) .| UInt64.(output.index_lower)
    all(H3.API.isValidCell, reconstructed) || error("Europe output contains invalid H3 ids")
    allunique(zip(output.code, output.x, output.y, reconstructed)) ||
        error("Europe output contains duplicate source-target rows")
    target_totals = combine(
        groupby(output, [:code, :x, :y]),
        :weight_mean => sum => :weight_mean,
    )
    maximum(abs.(target_totals.weight_mean .- 1)) <= 1e-10 ||
        error("Europe target weights do not sum to one")
    for target in groupby(output, [:code, :x, :y])
        transported = Float64.(target.weight) .* Float64.(target.population)
        expected = transported ./ sum(transported)
        maximum(abs.(Float64.(target.weight_mean) .- expected)) <= 1e-10 ||
            error("Europe target weights do not match transported population")
    end
    if !isnothing(sources)
        source_ids = UInt64.(sources.id)
        Set(reconstructed) == Set(source_ids) ||
            error("Europe output does not contain every source exactly by id")
        source_rows = Dict(
            id => (code=Int(code), population=Float64(population))
            for (id, code, population) in
                zip(source_ids, sources.country_code, sources.value)
        )
        for row in eachindex(reconstructed)
            source = source_rows[reconstructed[row]]
            output.code[row] == source.code || error("Europe output source has the wrong code")
            isapprox(output.population[row], source.population; rtol=0, atol=0) ||
                error("Europe output source has the wrong population")
        end
        source_totals = combine(
            groupby(DataFrame(id=reconstructed, weight=output.weight), :id),
            :weight => sum => :weight,
        )
        minimum(source_totals.weight) >= 0.99 ||
            error("Europe output retained less than 99% for a source")
        maximum(source_totals.weight) <= 1 + 1e-10 ||
            error("Europe output assigned more than 100% of a source")
        sum(output.weight .* output.population) / sum(Float64.(sources.value)) >= 0.99 ||
            error("Europe output retained less than 99% of total population")
    end
    if !isnothing(factor)
        expected_targets = Set{Tuple{Int,Any,Any}}()
        for country in eachrow(countries)
            cartogram = load_cartogram(country.cartogram_code; factor)
            union!(
                expected_targets,
                ((country.source_code, x, y) for (x, y) in zip(cartogram.x, cartogram.y)),
            )
        end
        Set(zip(output.code, output.x, output.y)) == expected_targets ||
            error("Europe output targets do not match the configured cartogram cells")
    end
    return nothing
end

function main(args=ARGS)
    length(args) <= 3 || error(
        "usage: europe.jl [SUBDIVISION_FACTOR] [OUTPUT.arrow] [SOURCE_CACHE.arrow]",
    )
    factor = length(args) >= 1 ? parse(Int, args[1]) : 1
    factor > 0 || error("subdivision factor must be positive")
    output_path = length(args) >= 2 ? abspath(args[2]) :
                  joinpath(DEFAULT_OUTPUT_DIR, "cartogram_weights_europe_factor$(factor)_hilo.arrow")
    source_path = length(args) >= 3 ? abspath(args[3]) : DEFAULT_SOURCE_CACHE
    CUDA.functional(true) || error("Europe fitting requires a functional CUDA device")
    countries = load_countries()
    names = city_names()
    sources = load_sources(source_path; countries)
    mapping = fit_europe(countries, sources; factor)
    assign_labels!(mapping, names)
    output = hilo_output(mapping)
    validate_output(output, countries; sources, factor)
    mkpath(dirname(output_path))
    Arrow.write(output_path, output)
    println("Wrote $(nrow(output)) Europe cartogram weights to $output_path")
    return output_path
end

end
if abspath(PROGRAM_FILE) == @__FILE__
    EuropeExample.main(ARGS)
end
