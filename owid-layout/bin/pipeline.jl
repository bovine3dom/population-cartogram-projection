using OWIDLayout, JSON
4<=length(ARGS)<=5 || error("Usage: pipeline.jl KONTUR.arrow NATURAL_EARTH.geojson CARTOGRAM.csv OUTPUT_DIR [OPTIONS.json]")
kontur,boundary,cartogram,output=ARGS[1:4]
options=length(ARGS)==5 ? JSON.parsefile(ARGS[5]) : Dict()
allowed=Set(["resolution","country_codes","scope_crosswalk","node_limit"])
issubset(Set(keys(options)),allowed) || error("Unknown pipeline option")
resolution=get(options,"resolution",5)
resolution isa Integer && 0<=resolution<=8 || error("Resolution must be in 0:8")
layout_options=Dict(Symbol(k)=>v for (k,v) in options if k!="resolution")
ispath(output) && error("Use a new pipeline directory. Use fit-mapping.jl to resume mapping.")
OWIDLayout.build_layout(kontur,boundary,cartogram,output;layout_options...)
OWIDLayout.fit_export(output,joinpath(output,"mapping");resolution)
println("Complete: ",joinpath(output,"mapping/h3-mon"))
