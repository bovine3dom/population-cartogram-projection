#!/usr/bin/env julia

module KonturCountryExtract

using Arrow
using DataFrames
using H3
using JSON

const DEFAULT_BOUNDARY = joinpath(@__DIR__, "..", "make-lookup-table", "population-data",
                                  "country-boundaries", "ne_10m_admin_0_map_units.geojson")

function polygon_cells(rings, resolution)
    vertices = [[H3.Lib.LatLng(deg2rad(p[2]), deg2rad(p[1])) for p in ring] for ring in rings]
    GC.@preserve vertices begin
        loops = [H3.Lib.GeoLoop(length(v), pointer(v)) for v in vertices]
        holes = loops[2:end]
        GC.@preserve holes begin
            polygon = Ref(H3.Lib.GeoPolygon(first(loops), length(holes), pointer(holes)))
            size = Ref{Int64}(0)
            H3.Lib.maxPolygonToCellsSize(polygon, resolution, UInt32(0), size) == 0 ||
                error("H3 polygon size failed")
            cells = zeros(UInt64, size[])
            H3.Lib.polygonToCells(polygon, resolution, UInt32(0), cells) == 0 ||
                error("H3 polygon fill failed")
            return filter!(!iszero, cells)
        end
    end
end

function aggregate_sources(ids, population, code, resolution)
    0 <= resolution <= 8 || error("H3 resolution must be between 0 and 8")
    sources = DataFrame(id=UInt64.(H3.API.cellToParent.(ids, resolution)),
                        population=population, country_code=code)
    result = combine(groupby(sources, [:country_code, :id]), :population => sum => :population)
    isapprox(sum(result.population), sum(population); rtol=1e-12) || error("population total changed")
    return sort!(result, :id)
end

function main(args=ARGS)
    3 <= length(args) <= 5 || error(
        "usage: extract_kontur_country.jl POPULATION.arrow COUNTRY_CODE OUTPUT.arrow [RESOLUTION=8] [BOUNDARY.geojson]",
    )
    input, code_text, output = args[1:3]
    code = parse(Int, code_text)
    resolution = length(args) >= 4 ? parse(Int, args[4]) : 8
    0 <= resolution <= 8 || error("H3 resolution must be between 0 and 8")
    ispath(output) && error("refusing to overwrite $output")
    boundary = JSON.parsefile(length(args) == 5 ? args[5] : DEFAULT_BOUNDARY)
    country_cells = Set{UInt64}()
    for feature in boundary["features"]
        string(feature["properties"]["ISO_N3_EH"]) == lpad(string(code), 3, '0') || continue
        geometry = feature["geometry"]
        geometry["type"] in ("Polygon", "MultiPolygon") || error("unsupported geometry")
        polygons = geometry["type"] == "Polygon" ? [geometry["coordinates"]] : geometry["coordinates"]
        for polygon in polygons
            union!(country_cells, polygon_cells(polygon, 8))
        end
    end
    isempty(country_cells) && error("no boundary cells for country $code")
    table = Arrow.Table(input)
    rows = findall(id -> id in country_cells, table.h3)
    ids = UInt64.(table.h3[rows])
    population = Float64.(table.population[rows])
    isempty(ids) && error("country extract is empty")
    allunique(ids) || error("duplicate population H3 ids")
    all(id -> H3.API.isValidCell(id) && H3.API.getResolution(id) == 8, ids) ||
        error("invalid resolution-8 H3 ids")
    all(p -> isfinite(p) && p > 0, population) || error("invalid population")
    sources = aggregate_sources(ids, population, code, resolution)
    Arrow.write(output, sources)
    println("boundary_cells=$(length(country_cells)) children=$(length(ids)) " *
            "sources=$(nrow(sources)) resolution=$resolution population=$(sum(population))")
    println("Wrote $output; country membership uses H3 cell centres inside Natural Earth polygons.")
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    KonturCountryExtract.main()
end
