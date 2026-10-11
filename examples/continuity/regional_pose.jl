using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
include("pose_graph.jl")
using .ContinuityExperiment: CSV, DataFrame
const CE=ContinuityExperiment

length(ARGS)>=5 || error("usage: regional_pose.jl SOURCE_DIRECTORY NEW_OUTPUT RESOLUTION BORDERS.csv COUNTRY_CODES...")
source_dir,out=ARGS[1:2]; resolution=parse(Int,ARGS[3]); codes=parse.(Int,ARGS[5:end])
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
border_rows=CSV.read(ARGS[4],DataFrame)
borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(border_rows))
CSV.write(joinpath(out,"borders.csv"),border_rows)
CSV.write(joinpath(out,"country-order.csv"),DataFrame(code=codes))
write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(source_dir))\n" * read(`git rev-parse HEAD`,String))
countries=[CE.country(joinpath(source_dir,"country-$code-res$resolution.arrow"),code) for code in codes]
CE.checkpoint(joinpath(out,"countries.jls"),countries)
edges=CE.graph(countries;borders)
contacts=Dict{Tuple{Int,Int},Int}()
all_pairs=Set(minmax(a,b) for a in codes for b in codes if a!=b)
for (k,j,l,t) in CE.graph(countries;borders=all_pairs)
    k==l && continue
    pair=minmax(codes[k],codes[l])
    contacts[pair]=get(contacts,pair,0)+1
end
CSV.write(joinpath(out,"graph-audit.csv"),DataFrame([
    (;country_a=a,country_b=b,geographic=(a,b) in borders,cartogram_edges=get(contacts,(a,b),0),
      constrained=(a,b) in borders && get(contacts,(a,b),0)>0) for (a,b) in sort!(collect(union(borders,keys(contacts))))]))
weights=CE.edge_weights(edges,.25)
backend=oneAPI.oneAPIBackend()
eta=.002; angles=collect(0:45:315)
choices=Vector{Matrix{Float64}}[]
for c in countries
    plans=Matrix{Float64}[]
    for angle in angles
        result=CE.sinkhorn(CE.pose_cost(c,angle),c.a,c.b,backend;eta,tolerance=1e-4,accelerate=true)
        push!(plans,result.plan)
        println("$(now(UTC)) country=$(c.code) angle=$angle residual=$(result.marginal_error)");flush(stdout)
    end
    push!(choices,plans)
    CE.checkpoint(joinpath(out,"poses-$(c.code).jls"),plans)
end
CE.checkpoint(joinpath(out,"choices.jls"),choices)
baseline=first.(choices)
CE.checkpoint(joinpath(out,"baseline.jls"),baseline)
base_metrics=CE.metrics(countries,baseline,edges)
rows=NamedTuple[]
for strength in 5. .* length(countries) .* (1.,3.)
    fold_strength=.1strength
    unary,pair=PoseGraph.tables(countries,choices,edges,weights;strength,eta,fold_strength)
    selections=PoseGraph.search(unary,pair)
    push!(selections,(labels=ones(Int,length(countries)),sweeps=0,energy=PoseGraph.energy(unary,pair,ones(Int,length(countries)))))
    sort!(selections;by=r->r.energy)
    CSV.write(joinpath(out,"pose-selection-$strength.csv"),DataFrame([
        (;pose=join(angles[s.labels],'-'),sweeps=s.sweeps,energy=s.energy) for s in selections]))
    selected=nothing
    for selection in selections
        plans=[choices[k][j] for (k,j) in enumerate(selection.labels)]
        expected=CE.objective(countries,plans,edges,strength,eta;weights,scale_km=900.,form=:distribution,saturating=false)+
                 fold_strength*first(CE.fold_penalty_gradient(countries,plans,CE.triangles(countries);forces_only=true))
        isapprox(expected,selection.energy;rtol=1e-9,atol=1e-9) || error("pose table objective differs")
        m=CE.metrics(countries,plans,edges)
        if m.spread_mean<=1.25base_metrics.spread_mean && m.spread_p90<=1.25base_metrics.spread_p90 &&
           m.interior_p90<=4base_metrics.interior_p90 && m.interior_max<=4base_metrics.interior_max
            selected=plans
            write(joinpath(out,"selected-$strength.txt"),join(angles[selection.labels],'-')*"\n")
            break
        end
    end
    isnothing(selected) && error("no valid starting pose")
    for (label,seed) in (("original",baseline),("posed",selected))
        name="$label-strength$strength"; path=joinpath(out,name)
        println("$(now(UTC)) $name");flush(stdout)
        try
            result=CE.run_case(countries,backend,path;initial_plans=baseline,starting_plans=seed,
                borders,strength,border_share=.25,scale_km=900.,eta,
                outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","60")),
                form=:distribution,saturating=false,fold_strength,proximal=.1,
                interior_limit=4.,spread_limit=1.25,inner_tolerance=1e-4,accelerate=true,export_arrow=false)
            orientation=ContinuityDiagnostics.orientations(countries,deserialize(joinpath(path,"candidate.jls")))
            CSV.write(joinpath(path,"candidate-orientation.csv"),orientation)
            push!(rows,(;name,positive_area_km2=sum(orientation.positive_area_km2),last(result)...))
            CSV.write(joinpath(out,"summary.csv"),DataFrame(rows))
        catch e
            open(joinpath(out,"failures.log"),"a") do io
                println(io,name,": ",sprint(showerror,e,catch_backtrace()))
            end
            println("FAILED $name: ",sprint(showerror,e));flush(stdout)
        end
        GC.gc()
    end
end
println("Completed: $(now(UTC))")
