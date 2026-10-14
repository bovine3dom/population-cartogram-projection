using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==6 || error("usage: refine_grid.jl COARSE_STUDY COARSE_TRIAL SOURCE_DIRECTORY NEW_OUTPUT RESOLUTION FACTOR")
input,trial,source_dir,out=ARGS[1:4]
resolution,factor=parse.(Int,ARGS[5:6])
factor>=1 || error("invalid subdivision")
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
coarse=deserialize(joinpath(input,"countries.jls"))
coarse_plans=deserialize(joinpath(input,trial,"candidate.jls"))
(;settings,borders,border_factors)=ContinuityExperiment.saved_case(joinpath(input,trial),coarse;root=input)
countries=[ContinuityExperiment.country(joinpath(source_dir,"country-$(c.code)-res$resolution.arrow"),c.code;factor) for c in coarse]
for (c,d) in zip(coarse,countries)
    c.source.id==d.source.id && c.a≈d.a || error("this refinement requires the same source population")
end
relative=sqrt(length(first(countries).b)/length(first(coarse).b))
all(length(d.b)≈relative^2*length(c.b) for (c,d) in zip(coarse,countries)) || error("grid scales differ")
settings[:eta]/=relative^2
haskey(settings,:country_etas) && (settings[:country_etas]=Dict(k=>v/relative^2 for (k,v) in settings[:country_etas]))
settings[:internal_scale]=get(settings,:internal_scale,1.)*relative^2
settings[:border_scale]=get(settings,:border_scale,1.)*relative
settings[:fold_strength]=get(settings,:fold_strength,0.)*relative^2
settings[:fold_smoothing]=get(settings,:fold_smoothing,0.)/relative^2
settings[:outer_steps]=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","100"))
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(input))/$trial\n" * read(`git rev-parse HEAD`,String))
backend=oneAPI.oneAPIBackend()
eta=settings[:eta]
tolerance=get(settings,:inner_tolerance,1e-5)
baseline=Matrix{Float64}[]; seed=Matrix{Float64}[]
for (c,p,d) in zip(coarse,coarse_plans,countries)
    println("$(now(UTC)) Baseline $(d.code)");flush(stdout)
    push!(baseline,ContinuityExperiment.sinkhorn(d.cost,d.a,d.b,backend;eta,tolerance,anneal=true,accelerate=true).plan)
    centres=ContinuityExperiment.refined_centres(c,p,d)
    field=(code=d.code,xyz=centres,target=d.target)
    field_plan=ContinuityExperiment.Diagonal(fill(1/length(d.b),length(d.b)))
    CSV.write(joinpath(out,"field-$(d.code)-orientation.csv"),ContinuityDiagnostics.orientations([field],[field_plan]))
    cost=max.(0.,1 .- transpose(d.xyz)*centres)
    cost ./= max(maximum(cost),eps())
    println("$(now(UTC)) Geographic seed $(d.code)");flush(stdout)
    push!(seed,ContinuityExperiment.sinkhorn(cost,d.a,d.b,backend;eta,tolerance,anneal=true,accelerate=true).plan)
end
ContinuityExperiment.checkpoint(joinpath(out,"baseline.jls"),baseline)
ContinuityExperiment.checkpoint(joinpath(out,"seed.jls"),seed)
edges=ContinuityExperiment.graph(countries;borders)
for (name,plans) in (("baseline",baseline),("seed",seed))
    CSV.write(joinpath(out,"$name-metrics.csv"),DataFrame([ContinuityExperiment.metrics(countries,plans,edges)]))
    CSV.write(joinpath(out,"$name-orientation.csv"),ContinuityDiagnostics.orientations(countries,plans))
end
result=ContinuityExperiment.run_case(countries,backend,joinpath(out,"fit");
    settings...,initial_plans=baseline,starting_plans=seed,borders,border_factors,export_arrow=false)
orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(out,"fit","candidate.jls")))
CSV.write(joinpath(out,"fit","candidate-orientation.csv"),orientation)
CSV.write(joinpath(out,"summary.csv"),DataFrame([(;positive_triangles=sum(orientation.positive),positive_area_km2=sum(orientation.positive_area_km2),last(result)...)]))
println("Completed: $(now(UTC))")
