using OWIDLayout, JSON
length(ARGS)==3 || error("Usage: prepare-sources.jl KONTUR.arrow NATURAL_EARTH.geojson OUTPUT_DIR")
JSON.print(stdout,OWIDLayout.prepare_sources(ARGS...))
println()
