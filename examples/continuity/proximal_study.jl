using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==2 || error("usage: proximal_study.jl BASELINE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY")
input,out=ARGS
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
countries=deserialize(joinpath(input,"countries.jls"))
baseline=deserialize(joinpath(input,"border0.25-fold0.0","baseline.jls"))
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
rows=NamedTuple[]
for proximal in (.01,.1), fold_strength in (.01,.1)
    name="proximal$proximal-fold$fold_strength"
    path=joinpath(out,name)
    println("$(now(UTC)) $name"); flush(stdout)
    started=time()
    try
        result=ContinuityExperiment.run_case(countries,oneAPI.oneAPIBackend(),path;
            initial_plans=baseline,borders=Set([(24,180),(24,894),(180,894)]),
            strength=1.,border_share=.25,scale_km=900.,eta=.002,outer_steps=100,
            form=:distribution,saturating=false,fold_strength,proximal,
            interior_limit=2.,spread_limit=1.25,inner_tolerance=1e-4,export_arrow=false)
        orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(path,"candidate.jls")))
        CSV.write(joinpath(path,"candidate-orientation.csv"),orientation)
        push!(rows,(;name,seconds=time()-started,positive_triangles=sum(orientation.positive),
                    positive_area_km2=sum(orientation.positive_area_km2),last(result)...))
        CSV.write(joinpath(out,"summary.csv"),DataFrame(rows))
    catch e
        open(joinpath(out,"failures.log"),"a") do io
            println(io,name,": ",sprint(showerror,e,catch_backtrace()))
        end
        println("FAILED: ",sprint(showerror,e));flush(stdout)
    end
    GC.gc()
end
