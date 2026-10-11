using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame, mean

length(ARGS)==2 || error("usage: pose_study.jl BASELINE_STUDY_DIRECTORY NEW_OUTPUT_DIRECTORY")
input,out=ARGS
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(input))\n" * read(`git rev-parse HEAD`,String))
countries=deserialize(joinpath(input,"countries.jls"))
trials=sort(filter(name->isfile(joinpath(input,name,"baseline.jls")),readdir(input)))
baseline=deserialize(joinpath(input,first(trials),"baseline.jls"))
settings=CSV.read(joinpath(input,first(trials),"settings.csv"),DataFrame)
eta=only(settings.eta)
backend=oneAPI.oneAPIBackend()
borders=Set([(24,180),(24,894),(180,894),(466,854),(276,616)])
edges=ContinuityExperiment.graph(countries;borders)
weights=ContinuityExperiment.edge_weights(edges,.25)
angles=collect(0:45:315)
choices=Vector{Matrix{Float64}}[]
for (k,c) in enumerate(countries)
    plans=Matrix{Float64}[]
    x=(c.source.x.-mean(c.source.x)).*cosd(mean(c.source.y))
    y=c.source.y.-mean(c.source.y)
    for angle in angles
        if angle==0
            push!(plans,baseline[k])
        else
            source=copy(c.source)
            source.x=x.*cosd(angle).-y.*sind(angle)
            source.y=x.*sind(angle).+y.*cosd(angle)
            problem=ContinuityExperiment.PCP._prepare_problem(c.target,source)
            cost=[ContinuityExperiment.PCP._cost(problem,i,j) for i in eachindex(c.a),j in eachindex(c.b)]
            result=ContinuityExperiment.sinkhorn(cost,c.a,c.b,backend;eta,tolerance=1e-4,accelerate=true)
            push!(plans,result.plan)
        end
        println("$(now(UTC)) country=$(c.code) angle=$angle");flush(stdout)
    end
    push!(choices,plans)
end
ContinuityExperiment.checkpoint(joinpath(out,"choices.jls"),choices)
ContinuityExperiment.checkpoint(joinpath(out,"countries.jls"),countries)
rows=NamedTuple[]
best=Inf
for indices in Iterators.product((eachindex(angles) for c in countries)...)
    plans=[choices[k][i] for (k,i) in enumerate(indices)]
    orientation=ContinuityDiagnostics.orientations(countries,plans)
    metrics=ContinuityExperiment.metrics(countries,plans,edges)
    score=ContinuityExperiment.objective(countries,plans,edges,1.,eta;weights,scale_km=900.,form=:distribution,saturating=false)
    name=join(angles[collect(indices)],'-')
    push!(rows,(;name,objective=score,positive_area_km2=sum(orientation.positive_area_km2),metrics...))
    if score<best
        best=score
        ContinuityExperiment.checkpoint(joinpath(out,"best.jls"),plans)
    end
end
CSV.write(joinpath(out,"summary.csv"),DataFrame(rows))
println("Completed $(length(rows)) pose combinations. Best original objective=$best")
