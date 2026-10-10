#!/usr/bin/env julia

module UKH3Example

using Arrow
using CSV
using DataFrames
using H3
using PopulationCartogramProjection

include(joinpath(@__DIR__, "common.jl"))

const ROOT = normpath(joinpath(@__DIR__, ".."))
const UK_CODE = 826
const DEFAULT_SOURCE_PATH = joinpath(
    ROOT, "make-lookup-table", "population-data", "country-826-res6.arrow",
)
const DEFAULT_OUTPUT_DIR = joinpath(ROOT, "output", "uk-h3")

function h3_indexes(values)
    any(ismissing, values) && error("H3 ids cannot be missing")
    all(value -> value isa Integer && !(value isa Bool), values) ||
        error("H3 ids must contain integers")
    all(value -> 0 <= value <= typemax(UInt64), values) ||
        error("H3 ids must be representable as UInt64")
    indexes = UInt64.(values)
    all(H3.API.isValidCell, indexes) || error("source contains invalid H3 cells")
    return indexes
end

function load_sources(path::AbstractString=DEFAULT_SOURCE_PATH; country_code=UK_CODE)
    isfile(path) || error(
        "H3 cache not found at $path; for the UK, run " *
        "`julia scripts/extract_country_h3.jl 826 6` first",
    )
    cached = DataFrame(Arrow.Table(path))
    all(column -> column in propertynames(cached), (:id, :population, :country_code)) ||
        error("H3 cache is missing required columns")
    ids = h3_indexes(cached.id)
    allunique(ids) || error("H3 ids must be unique")
    length(unique(H3.API.getResolution.(ids))) == 1 ||
        error("H3 cache must contain one H3 resolution")
    all(==(country_code), cached.country_code) || error("H3 cache has the wrong country code")
    all(value -> value isa Real && isfinite(value) && value > 0, cached.population) ||
        error("population must be finite and positive")
    centres = H3.API.cellToLatLng.(ids)
    any(value -> value isa H3.API.H3ErrorCode, centres) && error("H3 centroid lookup failed")
    return DataFrame(
        id=ids,
        x=[rad2deg(centre.lng) for centre in centres],
        y=[rad2deg(centre.lat) for centre in centres],
        value=Float64.(cached.population),
    )
end

function main(args=ARGS; backend=KA.CPU(), country_code=UK_CODE)
    length(args) <= 3 || error(
        "usage: uk_h3.jl [SOURCE.arrow] [OUTPUT_DIRECTORY] [SUBDIVISION_FACTOR]",
    )
    source_path = length(args) >= 1 ? abspath(args[1]) : DEFAULT_SOURCE_PATH
    output_dir = length(args) >= 2 ? abspath(args[2]) : DEFAULT_OUTPUT_DIR
    factor = length(args) >= 3 ? parse(Int, args[3]) : 1
    sources = load_sources(source_path; country_code)
    cartogram = load_cartogram(country_code; factor)
    println("Using $(nrow(sources)) H3 sources and $(nrow(cartogram)) cartogram cells.")

    println("Backend: $backend")
    flush(stdout)
    elapsed = @elapsed mapping = distribute(select(cartogram, :x, :y), sources; backend)
    println("Distribution completed in $(round(elapsed; digits=2)) seconds.")
    population = projected_values(mapping, sources, cartogram)
    density = DataFrame(id=sources.id,
                        density=sources.value ./ Float64.(H3.API.cellAreaKm2.(sources.id)))
    contributions = leftjoin(mapping, density; on=:id, validate=(false, true))
    contributions.population_density = contributions.weight_mean .* contributions.density
    projected_density = combine(groupby(contributions, [:x, :y]),
                                :population_density => sum => :population_density)
    population = leftjoin(population, projected_density; on=[:x, :y])
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
        metric=["sources", "targets", "subdivision_factor", "mapping_rows", "retained_value",
                "h3_resolution", "source_population", "population_per_target", "solve_seconds", "backend"],
        value=string.(Any[
            nrow(sources),
            nrow(cartogram),
            factor,
            nrow(mapping),
            retained_value_share(mapping, sources),
            Int(H3.API.getResolution(first(sources.id))),
            sum(sources.value),
            sum(sources.value) / nrow(cartogram),
            elapsed,
            string(backend),
        ]),
    ))
    println("Wrote country $country_code H3 distribution to $output_dir")
    return paths
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    UKH3Example.main(ARGS)
end
