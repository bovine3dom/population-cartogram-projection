#!/usr/bin/env julia

using Arrow
using DataFrames
import H3
using StatsBase: quantile, weights

const ROOT = normpath(joinpath(@__DIR__, ".."))
const POPULATION_PATH = joinpath(
    ROOT,
    "make-lookup-table",
    "population-data",
    "kontur_population_20231101.arrow",
)
const BOUNDARY_PATH = joinpath(
    ROOT,
    "make-lookup-table",
    "population-data",
    "country-boundaries",
    "ne_10m_admin_0_map_units.arrow",
)

function sql_literal(value::AbstractString)
    any(iscntrl, value) && error("paths cannot contain control characters")
    return "'$(replace(value, '\\' => "\\\\", '\'' => "''"))'"
end

function h3_indexes(values, label)
    any(ismissing, values) && error("$label cannot be missing")
    all(value -> value isa Integer && !(value isa Bool), values) ||
        error("$label must contain integers")
    all(value -> 0 <= value <= typemax(UInt64), values) ||
        error("$label must be representable as UInt64")
    indexes = UInt64.(values)
    all(H3.API.isValidCell, indexes) || error("$label must contain valid H3 cells")
    return indexes
end

function main(args)
    length(args) in (2, 3) || error(
        "usage: extract_country_h3_density.jl SOURCE_EXTRACT.arrow H3_RESOLUTION [OUTPUT.arrow]",
    )
    source_path = abspath(args[1])
    resolution = parse(Int, args[2])
    0 <= resolution <= 8 || error("parent H3 resolution must be between 0 and 8")
    stem, extension = splitext(source_path)
    output_path = length(args) == 3 ? abspath(args[3]) : "$stem-density$extension"

    isfile(source_path) || error("source extract not found at $source_path")
    isfile(POPULATION_PATH) || error("population input not found at $POPULATION_PATH")
    isfile(BOUNDARY_PATH) || error("boundary input not found at $BOUNDARY_PATH")
    isdir(dirname(output_path)) || error("output directory does not exist: $(dirname(output_path))")
    ispath(output_path) && error("refusing to overwrite $output_path")
    clickhouse = Sys.which("clickhouse")
    isnothing(clickhouse) && error("clickhouse executable not found")

    source = DataFrame(Arrow.Table(source_path))
    required = (:id, :population, :x, :y, :country_code)
    all(column -> column in propertynames(source), required) ||
        error("source extract is missing required columns")
    source_ids = h3_indexes(source.id, "source id")
    allunique(source_ids) || error("source id must be unique")
    all(==(resolution), Int.(H3.API.getResolution.(source_ids))) ||
        error("requested resolution does not match the source extract")
    all(value -> value isa Integer && !(value isa Bool), source.country_code) ||
        error("source country_code must contain integers")
    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && value > 0, source.population) ||
        error("source population must be finite and positive")
    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && -180 <= value <= 180, source.x) ||
        error("source x must contain WGS84 longitudes")
    all(value -> value isa Real && !(value isa Bool) && isfinite(value) && -90 <= value <= 90, source.y) ||
        error("source y must contain WGS84 latitudes")

    suffix = "$(getpid()).$(time_ns())"
    child_path = "$output_path.children.$suffix"
    temporary_output = "$output_path.tmp.$suffix"
    query = """
        SELECT
            h3ToParent(population.h3, $resolution) AS id,
            population.h3 AS child_h3,
            population.population AS population
        FROM
        (
            SELECT assumeNotNull(h3) AS h3, assumeNotNull(population) AS population
            FROM file($(sql_literal(POPULATION_PATH)), Arrow)
            WHERE
                isNotNull(h3) AND
                isNotNull(population) AND
                h3IsValid(assumeNotNull(h3)) AND
                h3ToParent(assumeNotNull(h3), $resolution) IN
                (SELECT id FROM file($(sql_literal(source_path)), Arrow))
        ) AS population
        INNER JOIN
        (
            SELECT DISTINCT assumeNotNull(h3) AS h3
            FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
            WHERE
                isNotNull(h3) AND
                isNotNull(ISO_N3_EH) AND
                h3IsValid(assumeNotNull(h3)) AND
                h3ToParent(assumeNotNull(h3), $resolution) IN
                (SELECT id FROM file($(sql_literal(source_path)), Arrow))
        ) AS boundary USING (h3)
        INTO OUTFILE $(sql_literal(child_path))
        FORMAT Arrow
        SETTINGS max_threads = 1
        """

    try
        run(Cmd([clickhouse, "local", "--query", query]))
        children = DataFrame(Arrow.Table(child_path))
        nrow(children) > 0 || error("density query returned no child population rows")
        child_ids = h3_indexes(children.child_h3, "child_h3")
        allunique(child_ids) || error("density query returned duplicate child H3 rows")
        parents = H3.API.cellToParent.(child_ids, resolution)
        any(value -> value isa H3.API.H3ErrorCode, parents) &&
            error("H3 parent calculation failed")
        UInt64.(parents) == UInt64.(children.id) ||
            error("density query returned an incorrect H3 parent")
        all(
            value -> value isa Real && !(value isa Bool) && isfinite(value) && value > 0,
            children.population,
        ) || error("child population must be finite and positive")
        areas = H3.API.cellAreaKm2.(child_ids)
        any(value -> value isa H3.API.H3ErrorCode, areas) &&
            error("H3 area calculation failed")
        children.population_density = children.population ./ Float64.(areas)
        density = combine(
            groupby(children, :id),
            [:population_density, :population] =>
                ((value, population) -> quantile(value, weights(collect(population)), 0.5)) =>
                :population_density,
        )
        density = leftjoin(source[:, [:id, :country_code]], density; on=:id)
        any(ismissing, density.population_density) &&
            error("density query did not cover every source id")
        all(value -> isfinite(value) && value > 0, density.population_density) ||
            error("population density must be finite and positive")
        sort!(density, :id)
        Arrow.write(temporary_output, density)
        mv(temporary_output, output_path; force=false)
        println("wrote $output_path")
        println("sources=$(nrow(density)) child_rows=$(nrow(children))")
        println("density_range=$(extrema(density.population_density))")
    finally
        ispath(child_path) && rm(child_path; force=true)
        ispath(temporary_output) && rm(temporary_output; force=true)
    end
end

main(ARGS)
