using Dates, SHA, oneAPI
include("experiment.jl")
include(joinpath(@__DIR__, "..", "..", "scripts", "extract_kontur_country.jl"))
using .ContinuityExperiment

length(ARGS) == 1 || error("usage: run.jl OUTPUT_DIRECTORY")
outdir = abspath(only(ARGS))
ispath(outdir) && error("refusing to overwrite $outdir")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(outdir)
backend = oneAPI.oneAPIBackend()
println("Started: $(now()); backend=$backend")
oneAPI.versioninfo()
flush(stdout)
kontur = get(ENV, "KONTUR_ARROW", joinpath(homedir(),"projects","gtfs_ffs","data","kontur_h3.arrow"))
for (name, codes) in (("germany-poland", [276,616]), ("indonesia", [360]), ("russia", [643]))
    countries = map(codes) do code
        path = joinpath(outdir,"country-$code-res4.arrow")
        KonturCountryExtract.main([kontur,string(code),path,"4"])
        open(joinpath(outdir,"inputs.sha256"),"a") do io
            println(io, bytes2hex(open(sha256,path)), "  ",path)
        end
        ContinuityExperiment.country(path,code)
    end
    ContinuityExperiment.run_case(countries,backend,joinpath(outdir,name))
    GC.gc()
end
println("Completed: $(now())")
