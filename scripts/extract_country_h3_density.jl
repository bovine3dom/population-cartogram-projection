#!/usr/bin/env julia

using Arrow
using DataFrames
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

    suffix = "$(getpid()).$(time_ns())"
    child_path = "$output_path.children.$suffix"
    temporary_output = "$output_path.tmp.$suffix"
    query = """
        SELECT
            h3ToParent(population.h3, $resolution) AS id,
            population.population AS population
        FROM
        (
            SELECT assumeNotNull(h3) AS h3, assumeNotNull(population) AS population
            FROM file($(sql_literal(POPULATION_PATH)), Arrow)
            WHERE
                isNotNull(h3) AND
                isNotNull(population) AND
                h3ToParent(assumeNotNull(h3), $resolution) IN
                (SELECT id FROM file($(sql_literal(source_path)), Arrow))
        ) AS population
        INNER JOIN
        (
            SELECT assumeNotNull(h3) AS h3
            FROM file($(sql_literal(BOUNDARY_PATH)), Arrow)
            WHERE
                isNotNull(h3) AND
                isNotNull(ISO_N3_EH) AND
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
        density = combine(
            groupby(children, :id),
            :population =>
                (population -> quantile(population, weights(collect(population)), 0.5)) =>
                :population_density,
        )
        source_ids = DataFrame(Arrow.Table(source_path))[:, [:id]]
        density = leftjoin(source_ids, density; on=:id)
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
