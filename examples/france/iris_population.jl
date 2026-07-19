#!/usr/bin/env julia

module FranceIrisExample

using CSV
using CUDA
using DataFrames
using PopulationCartogramProjection

include(joinpath(@__DIR__, "..", "common.jl"))

const INPUT_PATH = joinpath(@__DIR__, "iris-population.csv")
const CITY_LABEL_PATH = joinpath(@__DIR__, "iris-cities.csv")
const FRANCE_CODE = 250

function load_sources(path::AbstractString=INPUT_PATH)
    raw = CSV.read(path, DataFrame; types=Dict(:index => String))
    has_coordinates = .!ismissing.(raw.longitude) .& .!ismissing.(raw.latitude)
    positive_population = [
        value isa Real && !(value isa Bool) && isfinite(value) && value > 0
        for value in raw.population
    ]
    included = has_coordinates .& positive_population
    selected = raw[included, :]
    sources = DataFrame(
        id=copy(selected.index),
        x=Float64.(selected.longitude),
        y=Float64.(selected.latitude),
        value=Float64.(selected.population),
    )
    attributes = DataFrame(
        id=copy(selected.index),
        area_km2=Float64.(selected.area_km2),
        population_density=Float64.(selected.population_density),
    )
    report = (
        input_rows=nrow(raw),
        included_rows=nrow(sources),
        missing_coordinate_rows=count(!, has_coordinates),
        nonpositive_population_rows=count(!, positive_population),
        excluded_rows=count(!, included),
        input_population=sum(Float64.(raw.population)),
        included_population=sum(sources.value),
    )
    return (; sources, attributes, report)
end

function load_city_labels(path::AbstractString=CITY_LABEL_PATH)
    return CSV.read(path, DataFrame; types=Dict(:id => String))
end

function dominant_sources(mapping, sources, cartogram)
    transported = transported_rows(mapping, sources)
    best = Dict{Tuple{Any,Any},Int}()
    totals = Dict{Tuple{Any,Any},Float64}()
    for row in 1:nrow(transported)
        key = (transported.x[row], transported.y[row])
        totals[key] = get(totals, key, 0.0) + transported.transported_value[row]
        if !haskey(best, key) || transported.transported_value[row] >
                                 transported.transported_value[best[key]]
            best[key] = row
        end
    end
    result = select(cartogram, :cell_id, :parent_cell_id, :x, :y)
    rename!(result, :x => :grid_x, :y => :grid_y)
    result.id = Union{Missing,eltype(sources.id)}[
        haskey(best, (x, y)) ? transported.id[best[(x, y)]] : missing
        for (x, y) in zip(result.grid_x, result.grid_y)
    ]
    result.transport_mass = [
        haskey(best, (x, y)) ? transported.transported_value[best[(x, y)]] : 0.0
        for (x, y) in zip(result.grid_x, result.grid_y)
    ]
    result.cell_transport_mass = [get(totals, (x, y), 0.0) for (x, y) in zip(result.grid_x, result.grid_y)]
    result.transport_share = Union{Missing,Float64}[
        total == 0 ? missing : mass / total
        for (mass, total) in zip(result.transport_mass, result.cell_transport_mass)
    ]
    return result
end

function projected_density(mapping, sources, attributes, cartogram)
    transported = leftjoin(
        transported_rows(mapping, sources),
        select(attributes, :id, :population_density);
        on=:id,
        validate=(false, true),
    )
    transported.density_numerator =
        transported.transported_value .* transported.population_density
    grouped = combine(
        groupby(transported, [:x, :y]; sort=false),
        :transported_value => sum => :projected_population,
        :density_numerator => sum => :density_numerator,
    )
    grouped.population_density = grouped.density_numerator ./ grouped.projected_population
    cells = leftjoin(
        select(cartogram, :cell_id, :parent_cell_id, :x, :y),
        select(grouped, :x, :y, :projected_population, :population_density);
        on=[:x, :y],
    )
    rename!(cells, :x => :grid_x, :y => :grid_y)
    return cells
end

function place_city_labels(mapping, labels, cartogram)
    mapping_rows = groupby(mapping, :id)
    available = Set(mapping.id)
    active = filter(:id => in(available), labels)
    placements = copy(active)
    placements.grid_x = Vector{eltype(cartogram.x)}(undef, nrow(active))
    placements.grid_y = Vector{eltype(cartogram.y)}(undef, nrow(active))
    for row in 1:nrow(active)
        footprint = mapping_rows[(id=active.id[row],)]
        total = sum(footprint.weight)
        centre_x = sum(footprint.x .* footprint.weight) / total
        centre_y = sum(footprint.y .* footprint.weight) / total
        selected = argmin((footprint.x .- centre_x) .^ 2 .+ (footprint.y .- centre_y) .^ 2)
        placements.grid_x[row] = footprint.x[selected]
        placements.grid_y[row] = footprint.y[selected]
    end
    cells = select(cartogram, :cell_id, :parent_cell_id, :x, :y)
    rename!(cells, :x => :grid_x, :y => :grid_y)
    labels_by_cell = Dict{Tuple{Any,Any},Vector{String}}()
    for row in eachrow(placements)
        push!(get!(labels_by_cell, (row.grid_x, row.grid_y), String[]), String(row.name))
    end
    cells.label = Union{Missing,String}[
        haskey(labels_by_cell, (x, y)) ? join(unique(labels_by_cell[(x, y)]), ", ") : missing
        for (x, y) in zip(cells.grid_x, cells.grid_y)
    ]
    return (; cells, placements)
end

function main(args=ARGS)
    length(args) <= 2 || error(
        "usage: iris_population.jl [SUBDIVISION_FACTOR] [OUTPUT_DIRECTORY]",
    )
    factor = length(args) >= 1 ? parse(Int, args[1]) : 1
    output_dir = length(args) >= 2 ? abspath(args[2]) :
                 normpath(joinpath(@__DIR__, "..", "..", "output", "france-iris-factor$factor"))
    (; sources, attributes, report) = load_sources()
    cartogram = load_cartogram(FRANCE_CODE; factor)
    println(
        "Using $(nrow(sources)) IRIS rows and $(nrow(cartogram)) cartogram cells " *
        "($(round(nrow(sources) / nrow(cartogram); digits=2)) sources/cell).",
    )
    println(
        "Excluded $(report.excluded_rows) rows: " *
        "$(report.missing_coordinate_rows) lacked metropolitan centroids and " *
        "$(report.nonpositive_population_rows) had non-positive population.",
    )

    # AMDGPU.ROCBackend(), Metal.MetalBackend(), and oneAPI.oneAPIBackend() also work.
    mapping = distribute(
        select(cartogram, :x, :y), sources; backend=CUDA.CUDABackend(),
    )
    assignment = dominant_sources(mapping, sources, cartogram)
    population = projected_values(mapping, sources, cartogram)
    rename!(population, :x => :grid_x, :y => :grid_y, :value => :population)
    density = projected_density(mapping, sources, attributes, cartogram)
    city_labels = place_city_labels(mapping, load_city_labels(), cartogram)
    density = leftjoin(
        density,
        select(city_labels.cells, :cell_id, :label);
        on=:cell_id,
        validate=(true, true),
    )

    paths = (;
        mapping=joinpath(output_dir, "mapping.csv"),
        dominant_assignment=joinpath(output_dir, "dominant_iris.csv"),
        population=joinpath(output_dir, "projected_population.csv"),
        population_density=joinpath(output_dir, "projected_population_density.csv"),
        city_labels=joinpath(output_dir, "city_labels.csv"),
        city_placements=joinpath(output_dir, "city_label_placements.csv"),
        summary=joinpath(output_dir, "summary.csv"),
    )
    mkpath(output_dir)
    CSV.write(paths.mapping, mapping)
    CSV.write(paths.dominant_assignment, assignment)
    CSV.write(paths.population, population)
    CSV.write(paths.population_density, density)
    CSV.write(paths.city_labels, city_labels.cells)
    CSV.write(paths.city_placements, city_labels.placements)
    CSV.write(paths.summary, DataFrame(
        metric=[
            "input_rows", "included_rows", "excluded_rows", "included_population",
            "subdivision_factor", "cartogram_cells", "sources_per_cell", "mapping_rows",
            "retained_value", "city_labels",
        ],
        value=string.(Any[
            report.input_rows,
            report.included_rows,
            report.excluded_rows,
            report.included_population,
            factor,
            nrow(cartogram),
            nrow(sources) / nrow(cartogram),
            nrow(mapping),
            retained_value_share(mapping, sources),
            nrow(city_labels.placements),
        ]),
    ))
    println("Wrote France IRIS distribution CSVs to $output_dir")
    return paths
end

end


if abspath(PROGRAM_FILE) == @__FILE__
    FranceIrisExample.main(ARGS)
end
