using Dates, SHA, oneAPI
include("experiment.jl")
include(joinpath(@__DIR__, "..", "..", "scripts", "extract_kontur_country.jl"))
using .ContinuityExperiment: Arrow, CSV, DataFrame, select, nrow

length(ARGS) == 2 || error("usage: africa.jl GLOBAL_HILO.arrow OUTPUT_DIRECTORY")
input, outdir = abspath.(ARGS)
ispath(outdir) && error("refusing to overwrite $outdir")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(outdir)
println("Started: $(now())")
oneAPI.versioninfo()
flush(stdout)
open(joinpath(outdir,"input.sha256"),"w") do io
    println(io,bytes2hex(open(sha256,input)),"  ",input)
end
raw = DataFrame(Arrow.Table(input))
raw.id = (UInt64.(raw.index_upper) .<< 32) .| UInt64.(raw.index_lower)
countries = map([24,180,894]) do code
    sources = unique(select(filter(r -> r.code==code,raw),:id,:population))
    allunique(sources.id) || error("conflicting source populations")
    all(p -> isfinite(p) && p>0,sources.population) || error("invalid population")
    aggregated = KonturCountryExtract.aggregate_sources(sources.id,sources.population,code,4)
    path = joinpath(outdir,"country-$code-res4.arrow")
    Arrow.write(path,aggregated)
    ContinuityExperiment.country(path,code)
end
backend = oneAPI.oneAPIBackend()
for scale_km in (300.0,900.0), strength in (0.001,0.01)
    println("Trial: scale_km=$scale_km strength=$strength")
    flush(stdout)
    ContinuityExperiment.run_case(countries,backend,
        joinpath(outdir,"scale$(Int(scale_km))-strength$strength");
        borders=Set([(24,180),(24,894),(180,894)]), border_share=0.8,
        scale_km,strength,interior_limit=1.05)
    GC.gc()
end
println("Completed: $(now())")
