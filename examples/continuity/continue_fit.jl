using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==3 || error("usage: continue_fit.jl STUDY_DIRECTORY TRIAL_NAME NEW_OUTPUT_DIRECTORY")
input,trial,out=ARGS
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
countries=deserialize(joinpath(input,"countries.jls"))
path=joinpath(input,trial)
baseline=deserialize(joinpath(path,"baseline.jls"))
seed=deserialize(joinpath(path,"candidate.jls"))
(;settings,borders,border_factors)=ContinuityExperiment.saved_case(path,countries;root=input)
border_pairs=sort!(collect(borders))
CSV.write(joinpath(out,"borders.csv"),DataFrame(country_a=first.(border_pairs),country_b=last.(border_pairs)))
settings[:outer_steps]=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","50"))
settings[:start_step]=parse(Int,get(ENV,"CONTINUITY_START_STEP","1"))
haskey(ENV,"CONTINUITY_COORDINATE") && (settings[:coordinate]=ENV["CONTINUITY_COORDINATE"]=="1")
for (key,variable) in ((:border_scale,"CONTINUITY_BORDER_SCALE"),(:strength,"CONTINUITY_STRENGTH"),
                       (:fold_strength,"CONTINUITY_FOLD_STRENGTH"),(:spread_limit,"CONTINUITY_SPREAD_LIMIT"),
                       (:proximal,"CONTINUITY_PROXIMAL"),(:fold_smoothing,"CONTINUITY_FOLD_SMOOTHING"))
    haskey(ENV,variable) && (settings[key]=parse(Float64,ENV[variable]))
end
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(path))\n" * read(`git rev-parse HEAD`,String))
result=ContinuityExperiment.run_case(countries,oneAPI.oneAPIBackend(),joinpath(out,"fit");
    settings...,initial_plans=baseline,starting_plans=seed,export_arrow=false,
    borders,border_factors)
orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(out,"fit","candidate.jls")))
CSV.write(joinpath(out,"fit","candidate-orientation.csv"),orientation)
CSV.write(joinpath(out,"summary.csv"),DataFrame([(;positive_triangles=sum(orientation.positive),positive_area_km2=sum(orientation.positive_area_km2),last(result)...)]))
println("Completed: $(now(UTC))")
