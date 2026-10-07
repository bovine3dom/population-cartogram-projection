#!/usr/bin/env julia

module UKH3MonExport

using Arrow, CSV, DataFrames, H3

lower(id) = UInt32(id & 0xffffffff)
upper(id) = UInt32(id >> 32)

function build_output(mapping, sources, cities; minimum_population=50_000)
    all(==(826), sources.country_code) || error("expected UK sources")
    all(id -> H3.API.isValidCell(id), sources.id) || error("invalid source H3 ids")
    resolution = Int(only(unique(H3.API.getResolution.(sources.id))))
    Set(mapping.id) == Set(sources.id) || error("mapping and source ids differ")
    output = leftjoin(mapping, select(sources, :id, :population, :country_code => :code);
                      on=:id, validate=(false, true), order=:left)
    all(w -> isfinite(w) && 0 < w <= 1, output.weight) || error("invalid source weights")
    all(w -> isfinite(w) && 0 < w <= 1, output.weight_mean) || error("invalid target weights")
    totals = combine(groupby(output, [:x, :y]), :weight_mean => sum => :total)
    all(t -> isapprox(t, 1; atol=1e-10), totals.total) || error("target weights do not sum to one")

    cities = filter(row -> row.country_code == "GB" && row.population > minimum_population, cities)
    sort!(cities, [:population, :name]; rev=[true, false])
    cities.id = UInt64[H3.API.latLngToCell(
        H3.API.LatLng(deg2rad(row.latitude), deg2rad(row.longitude)), resolution,
    ) for row in eachrow(cities)]
    available = Set(sources.id)
    unmatched = filter(row -> row.id ∉ available, cities)
    filter!(row -> row.id in available, cities)
    names = combine(groupby(cities, :id; sort=false),
                    :name => (v -> join(unique(v), ", ")) => :label,
                    :population => maximum => :prominence)
    output.label = Vector{Union{Missing,String}}(missing, nrow(output))
    output.prominence = Vector{Union{Missing,Float64}}(missing, nrow(output))
    groups = groupby(output, :id)
    for city in eachrow(names)
        rows = groups[(id=city.id,)]
        total = sum(rows.weight)
        x = sum(rows.x .* rows.weight) / total
        y = sum(rows.y .* rows.weight) / total
        chosen = argmin((rows.x .- x).^2 .+ (rows.y .- y).^2)
        rows.label[chosen] = city.label
        rows.prominence[chosen] = city.prominence
    end
    output.index_lower = lower.(output.id)
    output.index_upper = upper.(output.id)
    @assert ((UInt64.(output.index_upper) .<< 32) .| UInt64.(output.index_lower)) == output.id
    select!(output, :x, :y, :weight, :population, :code, :label, :weight_mean,
            :index_lower, :index_upper, :prominence)
    return (; output, unmatched)
end

function main(args=ARGS)
    length(args) == 4 || error(
        "usage: export_h3_mon.jl MAPPING.csv SOURCES.arrow CITIES.csv OUTPUT_hilo.arrow",
    )
    mapping_path, source_path, cities_path, output_path = args
    density_path = joinpath(dirname(output_path), "population_density_hilo.arrow")
    unmatched_path = joinpath(dirname(output_path), "unmatched_cities.csv")
    for path in (output_path, density_path, unmatched_path)
        ispath(path) && error("refusing to overwrite $path")
    end
    mapping = CSV.read(mapping_path, DataFrame; types=Dict(:id => UInt64))
    sources = DataFrame(Arrow.Table(source_path))
    cities = CSV.read(cities_path, DataFrame)
    result = build_output(mapping, sources, cities)
    Arrow.write(output_path, result.output; compress=nothing)
    CSV.write(unmatched_path, result.unmatched)
    Arrow.write(density_path, (
        index_lower=lower.(sources.id), index_upper=upper.(sources.id),
        value=sources.population ./ Float64.(H3.API.cellAreaKm2.(sources.id)),
    ); compress=nothing)
    println("Wrote $output_path: $(nrow(result.output)) rows, " *
            "$(count(!ismissing, result.output.label)) labels")
    println("Unmatched cities: $(nrow(result.unmatched)); see $unmatched_path")
    println("Wrote $density_path for the H3-MON data layer (people/km²)")
    return result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    UKH3MonExport.main()
end
