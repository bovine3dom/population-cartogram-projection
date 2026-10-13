#!/usr/bin/env julia

# Assign the same ring-hash identity format to dissolved country polygons.
include("prepare_world.jl")
using CSV, DataFrames, JSON

function prepare_dissolved(directory)
    names=["components.csv","original-to-dissolved.csv","polygons.geojson","complete.txt"]
    any(ispath(joinpath(directory,name)) for name in names) && error("dissolved identities already exist")
    boundary=JSON.parsefile(joinpath(directory,"boundaries.geojson"))
    rows=NamedTuple[]; crosswalk=NamedTuple[]
    for feature in boundary["features"]
        c=only(WorldComponents.polygons(Dict("features"=>[feature])))
        p=feature["properties"]
        push!(rows,(;component_id=c.component_id,country_id=c.country_id,map_unit=c.map_unit,name=c.name,
            raw_country_code=c.raw_country_code,population=p["population"],source_cells=p["source_cells"],
            holes=length(c.rings)-1,west=c.west,south=c.south,east=c.east,north=c.north))
        for original in p["original_components"]
            push!(crosswalk,(;original_component_id=original,component_id=c.component_id,country_id=c.country_id))
        end
        p["component_id"]=c.component_id
    end
    allunique(r.component_id for r in rows) || error("duplicate dissolved identities")
    allunique(r.original_component_id for r in crosswalk) || error("duplicate original identities")
    manifest=JSON.parsefile(joinpath(directory,"manifest.json"))
    sum(r.population for r in rows) == manifest["population"] || error("population changed")
    temp=mktempdir(directory;prefix="identities-")
    try
        CSV.write(joinpath(temp,"components.csv"),DataFrame(sort!(rows;by=r->r.component_id)))
        CSV.write(joinpath(temp,"original-to-dissolved.csv"),DataFrame(sort!(crosswalk;by=r->r.original_component_id)))
        open(io->JSON.print(io,boundary),joinpath(temp,"polygons.geojson"),"w")
        write(joinpath(temp,"complete.txt"),"input_polygons=$(length(crosswalk))\noutput_polygons=$(length(rows))\n")
        for name in names; mv(joinpath(temp,name),joinpath(directory,name)); end
    finally
        rm(temp;recursive=true,force=true)
    end
    println("Dissolved identities: $(length(crosswalk)) original polygons, $(length(rows)) output polygons")
end

if abspath(PROGRAM_FILE) == @__FILE__
    prepare_dissolved(only(ARGS))
end
