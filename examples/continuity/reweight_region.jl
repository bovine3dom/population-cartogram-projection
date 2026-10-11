using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
include("pose_graph.jl")
using .ContinuityExperiment: CSV, DataFrame
const CE=ContinuityExperiment

length(ARGS)==2 || error("usage: reweight_region.jl REGIONAL_STUDY NEW_OUTPUT")
input,out=ARGS
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
countries=deserialize(joinpath(input,"countries.jls"))
choices=deserialize(joinpath(input,"choices.jls"))
baseline=first.(choices)
raw=CSV.read(joinpath(input,"borders.csv"),DataFrame)
borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(raw))
CSV.write(joinpath(out,"borders.csv"),raw)
for (name,value) in (("countries",countries),("choices",choices),("baseline",baseline))
    CE.checkpoint(joinpath(out,"$name.jls"),value)
end
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(input))\n"*read(`git rev-parse HEAD`,String))
edges=CE.graph(countries;borders)
capacity=ContinuityDiagnostics.capacity_rms_bounds(countries,edges)
CSV.write(joinpath(out,"capacity.csv"),capacity)
pairs=sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k!=l]))
reference=CE.metrics(countries,baseline,edges)
angles=collect(0:45:315)
strength=5.0length(countries); eta=.002; fold_strength=.1strength
summaries=NamedTuple[]
for mode in ("local","capacity")
    scales=NamedTuple[]
    for (k,l) in pairs
        a,b=minmax(countries[k].code,countries[l].code)
        selected=filter(e->e[1]==e[3] || minmax(e[1],e[3])==(k,l),edges)
        m=CE.metrics(countries,baseline,selected)
        bound=maximum(r.all_edge_rms_lower_bound_km for r in eachrow(capacity) if minmax(r.country,r.neighbour)==(a,b))
        scale=max(1.,m.local_rms_all,mode=="capacity" ? bound : 0.)
        push!(scales,(;country_a=a,country_b=b,local_rms=m.local_rms_all,capacity_rms=bound,
                      scale_km=scale,edges=count(e->e[1]!=e[3],selected)))
    end
    table=DataFrame(scales)
    table.factor=1 ./ table.scale_km.^2
    table.factor.*=sum(table.edges)/sum(table.edges.*table.factor)
    CSV.write(joinpath(out,"$mode-factors.csv"),table)
    factors=Dict((r.country_a,r.country_b)=>r.factor for r in eachrow(table))
    weights=CE.edge_weights(edges,.25)
    for (i,(k,j,l,t)) in enumerate(edges)
        k==l || (weights[i]*=factors[minmax(countries[k].code,countries[l].code)])
    end
    unary,pair=PoseGraph.tables(countries,choices,edges,weights;strength,eta,fold_strength)
    selections=PoseGraph.search(unary,pair)
    push!(selections,(labels=ones(Int,length(countries)),sweeps=0,energy=PoseGraph.energy(unary,pair,ones(Int,length(countries)))))
    sort!(selections;by=r->r.energy)
    seed=nothing
    for selection in selections
        plans=[choices[k][j] for (k,j) in enumerate(selection.labels)]
        expected=CE.objective(countries,plans,edges,strength,eta;weights,scale_km=900.,form=:distribution,saturating=false)+
                 fold_strength*first(CE.fold_penalty_gradient(countries,plans,CE.triangles(countries);forces_only=true))
        isapprox(expected,selection.energy;rtol=1e-9,atol=1e-9) || error("pose objective differs")
        m=CE.metrics(countries,plans,edges)
        if m.spread_mean<=1.25reference.spread_mean && m.spread_p90<=1.25reference.spread_p90 &&
           m.interior_p90<=4reference.interior_p90 && m.interior_max<=4reference.interior_max
            seed=plans
            write(joinpath(out,"$mode-pose.txt"),join(angles[selection.labels],'-')*"\n")
            break
        end
    end
    isnothing(seed) && error("no valid starting pose")
    path=joinpath(out,mode)
    result=CE.run_case(countries,oneAPI.oneAPIBackend(),path;initial_plans=baseline,starting_plans=seed,
        borders,border_factors=factors,strength,eta,border_share=.25,scale_km=900.,
        form=:distribution,saturating=false,fold_strength,proximal=.1,coordinate=true,
        outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","20")),
        interior_limit=4.,spread_limit=1.25,inner_tolerance=1e-4,accelerate=true,export_arrow=false)
    orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(path,"candidate.jls")))
    CSV.write(joinpath(path,"candidate-orientation.csv"),orientation)
    push!(summaries,(;mode,positive_area_km2=sum(orientation.positive_area_km2),last(result)...))
    CSV.write(joinpath(out,"summary.csv"),DataFrame(summaries))
end
println("Completed: $(now(UTC))")
