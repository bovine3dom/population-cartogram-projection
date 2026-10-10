#!/usr/bin/env julia

using Dates, oneAPI

include(joinpath(@__DIR__, "..", "uk_h3.jl"))
include(joinpath(@__DIR__, "..", "uk-h3", "export_h3_mon.jl"))

length(ARGS) == 3 || error("usage: run.jl SOURCES.arrow CITIES.csv OUTPUT_DIRECTORY")
source_path, cities_path, output_dir = abspath.(ARGS)
ispath(output_dir) && error("refusing to overwrite $output_dir")
isfile(cities_path) || error("city input is missing")
oneAPI.functional() || error("oneAPI is not functional")
sources = UKH3Example.load_sources(source_path; country_code=276)
all(id -> UKH3Example.H3.API.getResolution(id) == 7, sources.id) ||
    error("expected H3-7 sources")
println("Started: $(now())")
oneAPI.versioninfo()
flush(stdout)
paths = UKH3Example.main([source_path, output_dir, "5"];
                         backend=oneAPI.oneAPIBackend(), country_code=276)
UKH3MonExport.main([paths.mapping, source_path, cities_path,
                    joinpath(output_dir, "cartogram_weights_germany_h3_7_factor5_hilo.arrow")];
                   country_code=276, city_country="DE")
println("Completed: $(now())")
