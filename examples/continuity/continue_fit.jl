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
row=only(eachrow(CSV.read(joinpath(path,"settings.csv"),DataFrame)))
mask=filter(isfile,[joinpath(path,"borders.csv"),joinpath(input,"borders.csv")])
borders=isempty(mask) ? Set([(24,180),(24,894),(180,894),(466,854),(276,616)]) :
    Set(minmax(r.country_a,r.country_b) for r in eachrow(CSV.read(first(mask),DataFrame)))
count(e->e[1]!=e[3],ContinuityExperiment.graph(countries;borders))==row.border_edges || error("border mask differs from checkpoint")
border_pairs=sort!(collect(borders))
CSV.write(joinpath(out,"borders.csv"),DataFrame(country_a=first.(border_pairs),country_b=last.(border_pairs)))
settings=Dict(Symbol(k)=>v for (k,v) in pairs(row) if !(k in (:internal_edges,:border_edges)))
settings[:form]=Symbol(settings[:form])
haskey(settings,:internal_form) && (settings[:internal_form]=Symbol(settings[:internal_form]))
ismissing(settings[:border_share]) && (settings[:border_share]=nothing)
settings[:outer_steps]=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","50"))
haskey(ENV,"CONTINUITY_COORDINATE") && (settings[:coordinate]=ENV["CONTINUITY_COORDINATE"]=="1")
for (key,variable) in ((:border_scale,"CONTINUITY_BORDER_SCALE"),(:strength,"CONTINUITY_STRENGTH"),
                       (:fold_strength,"CONTINUITY_FOLD_STRENGTH"),(:spread_limit,"CONTINUITY_SPREAD_LIMIT"),
                       (:proximal,"CONTINUITY_PROXIMAL"))
    haskey(ENV,variable) && (settings[key]=parse(Float64,ENV[variable]))
end
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(path))\n" * read(`git rev-parse HEAD`,String))
result=ContinuityExperiment.run_case(countries,oneAPI.oneAPIBackend(),joinpath(out,"fit");
    settings...,initial_plans=baseline,starting_plans=seed,export_arrow=false,
    borders)
orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(out,"fit","candidate.jls")))
CSV.write(joinpath(out,"fit","candidate-orientation.csv"),orientation)
CSV.write(joinpath(out,"summary.csv"),DataFrame([(;positive_triangles=sum(orientation.positive),positive_area_km2=sum(orientation.positive_area_km2),last(result)...)]))
println("Completed: $(now(UTC))")
