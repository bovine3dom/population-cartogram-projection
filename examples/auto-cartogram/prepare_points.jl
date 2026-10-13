#!/usr/bin/env julia

# Convert H3 centres once, then use a prepared-geometry spatial join. This avoids
# filling hundreds of millions of empty land cells with complex coastlines.
using Arrow, DataFrames, H3, JSON
include("prepare_world.jl")

function prepare_points(population_path, boundary_path, output)
    ispath(output) && error("refusing to overwrite $output")
    table = Arrow.Table(population_path)
    ids = UInt64.(table.h3)
    values = Float64.(table.population)
    allunique(ids) || error("duplicate H3 IDs")
    all(p -> isfinite(p) && p > 0, values) || error("invalid population")
    lon, lat = zeros(length(ids)), zeros(length(ids))
    for i in eachindex(ids)
        H3.API.isValidCell(ids[i]) && H3.API.getResolution(ids[i]) == 8 || error("invalid H3-8 ID")
        point = H3.API.cellToLatLng(ids[i])
        lon[i],lat[i] = rad2deg(point.lng),rad2deg(point.lat)
    end
    parts = WorldComponents.polygons(JSON.parsefile(boundary_path))
    features = [Dict("type"=>"Feature", "properties"=>Dict(
        "component_id"=>c.component_id,"component_index"=>i,"country_id"=>c.country_id,
        "map_unit"=>c.map_unit,"name"=>c.name,"raw_country_code"=>c.raw_country_code),
        "geometry"=>Dict("type"=>"Polygon","coordinates"=>c.rings)) for (i,c) in enumerate(parts)]
    mkpath(dirname(abspath(output)))
    temp = mktempdir(dirname(abspath(output));prefix="population-centres-")
    try
        Arrow.write(joinpath(temp,"centres.arrow"),(;id=ids,value=values,longitude=lon,latitude=lat))
        open(io->JSON.print(io,Dict("type"=>"FeatureCollection","features"=>features)),joinpath(temp,"polygons.geojson"),"w")
        manifest=Dict("source_cells"=>length(ids),"population_total"=>sum(values),"polygon_components"=>length(parts),
            "julia_version"=>string(VERSION),"population_year"=>"not declared by input Arrow",
            "inputs"=>[Dict("path"=>abspath(p),"sha256"=>WorldComponents.IslandAudit.file_hash(p))
                for p in (population_path,boundary_path,@__FILE__,joinpath(@__DIR__,"prepare_world.jl"))])
        open(io->JSON.print(io,manifest,2),joinpath(temp,"manifest.json"),"w")
        mv(temp,output)
    finally
        ispath(temp) && rm(temp;recursive=true)
    end
    println("Wrote $(length(ids)) native H3 centres and $(length(parts)) polygon components to $output")
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS)==3 || error("usage: prepare_points.jl POPULATION.arrow BOUNDARY.geojson NEW_DIR")
    prepare_points(ARGS...)
end
