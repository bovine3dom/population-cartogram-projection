using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==6 || error("usage: refine_grid.jl COARSE_STUDY COARSE_TRIAL SOURCE_DIRECTORY NEW_OUTPUT RESOLUTION FACTOR")
input,trial,source_dir,out=ARGS[1:4]
resolution,factor=parse.(Int,ARGS[5:6])
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
coarse=deserialize(joinpath(input,"countries.jls"))
coarse_plans=deserialize(joinpath(input,trial,"candidate.jls"))
countries=[ContinuityExperiment.country(joinpath(source_dir,"country-$(c.code)-res$resolution.arrow"),c.code;factor) for c in coarse]
for (c,d) in zip(coarse,countries)
    c.source.id==d.source.id && c.a≈d.a || error("this refinement requires the same source population")
end
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(input))/$trial\n" * read(`git rev-parse HEAD`,String))
backend=oneAPI.oneAPIBackend()
eta=.002/factor^2
baseline=Matrix{Float64}[]; seed=Matrix{Float64}[]
for (c,p,d) in zip(coarse,coarse_plans,countries)
    println("$(now(UTC)) Baseline $(d.code)");flush(stdout)
    push!(baseline,ContinuityExperiment.sinkhorn(d.cost,d.a,d.b,backend;eta,tolerance=1e-4,anneal=true,accelerate=true).plan)
    centres=ContinuityExperiment.refined_centres(c,p,d)
    cost=max.(0.,1 .- transpose(d.xyz)*centres)
    cost ./= maximum(cost)
    println("$(now(UTC)) Geographic seed $(d.code)");flush(stdout)
    push!(seed,ContinuityExperiment.sinkhorn(cost,d.a,d.b,backend;eta,tolerance=1e-4,anneal=true,accelerate=true).plan)
end
ContinuityExperiment.checkpoint(joinpath(out,"baseline.jls"),baseline)
ContinuityExperiment.checkpoint(joinpath(out,"seed.jls"),seed)
borders=Set([(24,180),(24,894),(180,894),(466,854),(276,616)])
edges=ContinuityExperiment.graph(countries;borders)
for (name,plans) in (("baseline",baseline),("seed",seed))
    CSV.write(joinpath(out,"$name-metrics.csv"),DataFrame([ContinuityExperiment.metrics(countries,plans,edges)]))
    CSV.write(joinpath(out,"$name-orientation.csv"),ContinuityDiagnostics.orientations(countries,plans))
end
result=ContinuityExperiment.run_case(countries,backend,joinpath(out,"fit");
    initial_plans=baseline,starting_plans=seed,borders,strength=10.,border_share=.25,
    scale_km=900.,eta,outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","100")),
    form=:distribution,saturating=false,fold_strength=1.*factor^2,proximal=.1,internal_scale=factor^2,
    interior_limit=4.,spread_limit=1.25,inner_tolerance=1e-4,accelerate=true,export_arrow=false)
orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(out,"fit","candidate.jls")))
CSV.write(joinpath(out,"fit","candidate-orientation.csv"),orientation)
CSV.write(joinpath(out,"summary.csv"),DataFrame([(;positive_triangles=sum(orientation.positive),positive_area_km2=sum(orientation.positive_area_km2),last(result)...)]))
println("Completed: $(now(UTC))")
