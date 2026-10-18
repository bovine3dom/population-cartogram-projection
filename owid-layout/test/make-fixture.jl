# Regenerate geometry descriptors, not expected identities.
using OWIDLayout, CSV
length(ARGS) == 2 || error("Usage: make-fixture.jl components.csv polygons.geojson")
codes = OWIDLayout.code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
sources = read_sources(ARGS[1],ARGS[2],codes)
scopes = Set(String(r.country) for r in CSV.File(joinpath(@__DIR__,"fixtures","expected-identities.csv")))
rows = [(;scope,id=p.id,mass=p.mass,x=p.centre[1],y=p.centre[2],
         west=p.bounds[1],south=p.bounds[2],east=p.bounds[3],north=p.bounds[4])
        for scope in sort!(collect(scopes)) for p in sort(sources[scope];by=p->p.id)]
CSV.write(joinpath(@__DIR__,"fixtures","source-descriptors.csv"),rows)
