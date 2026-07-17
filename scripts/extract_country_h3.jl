#!/usr/bin/env julia

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
        "usage: julia scripts/extract_country_h3.jl COUNTRY_CODE H3_RESOLUTION [OUTPUT.arrow]",
    )
    country_code = parse(Int, args[1])
    country_code_text = country_code >= 0 ? lpad(string(country_code), 3, '0') : string(country_code)
    resolution = parse(Int, args[2])
    0 <= resolution <= 8 || error("parent H3 resolution must be between 0 and 8")
    output_path = length(args) == 3 ? abspath(args[3]) : joinpath(
        ROOT,
        "make-lookup-table",
        "population-data",
        "country-$(country_code)-res$(resolution).arrow",
    )

    isfile(POPULATION_PATH) || error("population input not found at $POPULATION_PATH")
    isfile(BOUNDARY_PATH) || error("boundary input not found at $BOUNDARY_PATH")
    isdir(dirname(output_path)) || error("output directory does not exist: $(dirname(output_path))")
    ispath(output_path) && error("refusing to overwrite $output_path")
    clickhouse = Sys.which("clickhouse")
    isnothing(clickhouse) && error("clickhouse executable not found")

    temporary_path = "$output_path.tmp.$(getpid()).$(time_ns())"
    ispath(temporary_path) && error("temporary output already exists: $temporary_path")
    population_path_sql = sql_literal(POPULATION_PATH)
    boundary_path_sql = sql_literal(BOUNDARY_PATH)
    temporary_path_sql = sql_literal(temporary_path)
    query = """
        SELECT
            assumeNotNull(parent) AS id,
            parent_population AS population,
            tupleElement(h3ToGeo(assumeNotNull(parent)), 2) AS x,
            tupleElement(h3ToGeo(assumeNotNull(parent)), 1) AS y,
            toInt64(parent_code) AS country_code
        FROM
        (
            SELECT
                parent,
                sum(code_population) AS parent_population,
                tupleElement(arrayElement(arraySort(
                    item -> (-tupleElement(item, 2), tupleElement(item, 3)),
                    groupArray((code, code_rows, first_row))
                ), 1), 1) AS parent_code
            FROM
            (
                SELECT
                    h3ToParent(population.h3, $resolution) AS parent,
                    toInt32(boundary.ISO_N3_EH) AS code,
                    count() AS code_rows,
                    min(population.row_index) AS first_row,
                    sum(population.population) AS code_population
                FROM
                (
                    SELECT
                        assumeNotNull(h3) AS h3,
                        assumeNotNull(population) AS population,
                        rowNumberInAllBlocks() AS row_index
                    FROM file($population_path_sql, Arrow)
                    WHERE isNotNull(h3) AND isNotNull(population)
                ) AS population
            INNER JOIN
            (
                SELECT h3, ISO_N3_EH
                FROM file($boundary_path_sql, Arrow)
                WHERE h3ToParent(h3, $resolution) IN
                (
                    SELECT DISTINCT h3ToParent(h3, $resolution)
                    FROM file($boundary_path_sql, Arrow)
                    WHERE ISO_N3_EH = '$country_code_text'
                )
            ) AS boundary USING (h3)
                GROUP BY parent, code
            )
            GROUP BY parent
        )
        WHERE parent_code = $country_code
        ORDER BY id
        INTO OUTFILE $temporary_path_sql
        FORMAT Arrow
        SETTINGS max_threads = 1, h3togeo_lon_lat_result_order = 0
        """

    try
        run(Cmd([clickhouse, "local", "--query", query]))
        verify_query = """
            SELECT
                count(),
                sum(population),
                count() - uniqExact(id),
                countIf(id = 0 OR h3GetResolution(id) != $resolution),
                countIf(country_code != $country_code),
                countIf(
                    NOT isFinite(x) OR x < -180 OR x > 180 OR
                    NOT isFinite(y) OR y < -90 OR y > 90
                ),
                countIf(population <= 0 OR NOT isFinite(toFloat64(population)))
            FROM file($(sql_literal(temporary_path)), Arrow)
            FORMAT TSV
            """
        summary = strip(read(Cmd([clickhouse, "local", "--query", verify_query]), String))
        fields = split(summary, '\t')
        length(fields) == 7 || error("unexpected verification output: $summary")
        rows = parse(Int, fields[1])
        rows > 0 || error("country extract is empty")
        violation_labels = (
            "duplicate ids",
            "invalid H3 ids",
            "wrong country codes",
            "invalid coordinates",
            "invalid populations",
        )
        violations = parse.(Int, fields[3:7])
        all(iszero, violations) || error(join(
            ("$label=$count" for (label, count) in zip(violation_labels, violations) if count > 0),
            ", ",
        ))
        mv(temporary_path, output_path; force=false)
        println("wrote $output_path")
        println("rows\tpopulation")
        println("$(fields[1])\t$(fields[2])")
    finally
        ispath(temporary_path) && rm(temporary_path; force=true)
    end
end

main(ARGS)
