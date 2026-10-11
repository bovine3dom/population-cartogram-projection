using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==3 || error("usage: pose_refine.jl BASELINE_STUDY_DIRECTORY POSE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY")
input,poses,out=ARGS
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
countries=deserialize(joinpath(input,"countries.jls"))
getproperty.(countries,:code)==[466,854] || error("this pilot expects Mali and Burkina Faso")
trials=sort(filter(name->isfile(joinpath(input,name,"baseline.jls")),readdir(input)))
baseline=deserialize(joinpath(input,first(trials),"baseline.jls"))
choices=deserialize(joinpath(poses,"choices.jls"))
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
rows=NamedTuple[]
for indices in ((7,7),(7,8),(8,8)), strength in (1.,10.)
    name="pose$(45(indices[1]-1))-$(45(indices[2]-1))-strength$strength"
    path=joinpath(out,name)
    println("$(now(UTC)) $name");flush(stdout)
    try
        seed=[choices[k][j] for (k,j) in enumerate(indices)]
        result=ContinuityExperiment.run_case(countries,oneAPI.oneAPIBackend(),path;
            initial_plans=baseline,starting_plans=seed,borders=Set([(466,854)]),
            strength,border_share=.25,scale_km=900.,eta=.002,outer_steps=100,
            form=:distribution,saturating=false,fold_strength=.1strength,proximal=.1,
            interior_limit=4.,spread_limit=1.25,inner_tolerance=1e-4,accelerate=true,export_arrow=false)
        orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(path,"candidate.jls")))
        CSV.write(joinpath(path,"candidate-orientation.csv"),orientation)
        push!(rows,(;name,positive_triangles=sum(orientation.positive),positive_area_km2=sum(orientation.positive_area_km2),last(result)...))
        CSV.write(joinpath(out,"summary.csv"),DataFrame(rows))
    catch e
        open(joinpath(out,"failures.log"),"a") do io
            println(io,name,": ",sprint(showerror,e,catch_backtrace()))
        end
        println("FAILED: ",sprint(showerror,e));flush(stdout)
    end
    GC.gc()
end
