#!/usr/bin/env julia
# H3 parents follow the same native-resolution hierarchy as population sources.
using CSV, DataFrames, H3
function prepare(sources_path,cities_path,output)
    ispath(output) && error("Output already exists")
    sources=CSV.read(sources_path,DataFrame)
    ids=sort!(unique(parse(UInt64,last(rsplit(id,':';limit=2))) for id in sources.id))
    cities=CSV.read(cities_path,DataFrame;delim='\t',header=false,select=[1,2,5,6,9,15])
    rename!(cities,[:geoname_id,:name,:latitude,:longitude,:country_code,:population])
    filter!(r->r.population>50_000,cities)
    cities.native_h3=UInt64[H3.API.latLngToCell(H3.API.LatLng(deg2rad(r.latitude),deg2rad(r.longitude)),8) for r in eachrow(cities)]
    cities.h3=H3.API.cellToParent.(cities.native_h3,5)
    mkpath(output)
    CSV.write(joinpath(output,"cities.csv"),cities)
    CSV.write(joinpath(output,"areas.csv"),DataFrame(h3=ids,area_km2=Float64.(H3.API.cellAreaKm2.(ids))))
end
if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==3 || error("Usage: prepare_h3_labels.jl COMPONENT_SOURCES.csv GEONAMES.tsv OUTPUT")
    prepare(ARGS...)
end
