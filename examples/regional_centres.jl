#!/usr/bin/env julia

module RegionalCentresExample

using CSV
using DataFrames
using PopulationCartogramProjection

include(joinpath(@__DIR__, "common.jl"))

const FIXTURE_PATH = joinpath(EXAMPLE_ROOT, "test", "fixtures", "synthetic_sources.csv")

function main(args=ARGS)
    length(args) <= 1 || error("usage: regional_centres.jl [output-directory]")
    output_dir = isempty(args) ? joinpath(EXAMPLE_ROOT, "output", "regional-centres") :
                 abspath(only(args))
    raw = CSV.read(FIXTURE_PATH, DataFrame)
    country = only(unique(raw.country_code))
    sources = DataFrame(id=raw.id, x=raw.x, y=raw.y, value=raw.population)
    cartogram = load_cartogram(country)
    mapping = distribute(select(cartogram, :x, :y), sources; backend=KA.CPU())
    population = projected_values(mapping, sources, cartogram)
    rename!(population, :x => :grid_x, :y => :grid_y, :value => :population)
    paths = (;
        mapping=joinpath(output_dir, "mapping.csv"),
        population=joinpath(output_dir, "projected_population.csv"),
        summary=joinpath(output_dir, "summary.csv"),
    )
    mkpath(output_dir)
    CSV.write(paths.mapping, mapping)
    CSV.write(paths.population, population)
    CSV.write(paths.summary, DataFrame(
        metric=["mapping_rows", "retained_value"],
        value=string.(Any[nrow(mapping), retained_value_share(mapping, sources)]),
    ))
    println("Wrote regional distribution CSVs to $output_dir")
    return paths
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    RegionalCentresExample.main(ARGS)
end
