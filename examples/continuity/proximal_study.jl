using Serialization, Dates, SHA, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

2<=length(ARGS)<=3 || error("usage: proximal_study.jl BASELINE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY [FACTOR=1]")
input,out=ARGS[1:2]
factor=length(ARGS)==3 ? parse(Int,ARGS[3]) : 1
factor>0 || error("factor must be positive")
selected=Set(filter(!isempty,split(get(ENV,"CONTINUITY_PROXIMAL_CASES",""),',')))
outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","100"))
interior_limit=parse(Float64,get(ENV,"CONTINUITY_INTERIOR_LIMIT","2"))
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
countries=deserialize(joinpath(input,"countries.jls"))
trials=sort(filter(name->isfile(joinpath(input,name,"baseline.jls")),readdir(input)))
isempty(trials) && error("no complete baseline")
baseline=deserialize(joinpath(input,first(trials),"baseline.jls"))
settings=CSV.read(joinpath(input,first(trials),"settings.csv"),DataFrame)
isapprox(only(settings.eta),.002/factor^2) || error("factor does not match baseline entropy")
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
open(joinpath(out,"provenance.txt"),"w") do io
    println(io,"Started: $(now(UTC)) UTC\nBaseline trial: $(first(trials))\nFactor: $factor")
    for path in [@__FILE__,joinpath(@__DIR__,"experiment.jl"),joinpath(input,"countries.jls"),
                 joinpath(input,first(trials),"baseline.jls")]
        println(io,bytes2hex(open(sha256,path)),"  ",abspath(path))
    end
end
rows=NamedTuple[]
for proximal in (.01,.1), fold_strength in (.01,.1)
    name="proximal$proximal-fold$fold_strength"
    isempty(selected) || name in selected || continue
    path=joinpath(out,name)
    println("$(now(UTC)) $name"); flush(stdout)
    started=time()
    try
        result=ContinuityExperiment.run_case(countries,oneAPI.oneAPIBackend(),path;
            initial_plans=baseline,borders=Set([(24,180),(24,894),(180,894),(466,854),(276,616)]),
            strength=1.,border_share=.25,scale_km=900.,eta=.002/factor^2,outer_steps,
            form=:distribution,saturating=false,fold_strength=fold_strength*factor^2,proximal,
            internal_scale=factor^2,accelerate=true,
            interior_limit,spread_limit=1.25,inner_tolerance=1e-4,export_arrow=false)
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
