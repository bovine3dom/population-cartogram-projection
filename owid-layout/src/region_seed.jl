"""Fit whole country regions to cell costs without inherited border constraints.

Exact counts, coast status, and connectivity are hard constraints. Neighbour
relationships are deliberately left for the geographic audit and later edits.
"""
function seed_region(reference,outside,costs;inland=Set{String}(),node_limit=100,rounds=20)
    labels=sort!(collect(keys(reference)));points=sort!([p for ps in values(reference) for p in ps])
    lookup=Dict(p=>i for (i,p) in enumerate(points));occupied=union(Set(points),Set(keys(outside)))
    water=enclosed_cells(occupied)
    coast=[i for (i,p) in enumerate(points) if any(begin q=(p[1]+dx,p[2]+dy);q ∉ occupied && q ∉ water end for (dx,dy) in EDGE_OFFSETS)]
    n,k=length(points),length(labels)
    size(costs)==(n,k) && all(isfinite,costs) || error("Invalid seed costs")
    model=JuMP.Model(HiGHS.Optimizer);JuMP.set_silent(model)
    for (name,value) in (("threads",1),("parallel","off"),("random_seed",0),("mip_max_nodes",node_limit),("mip_rel_gap",.002))
        JuMP.set_optimizer_attribute(model,name,value)
    end
    JuMP.@variable(model,x[1:n,1:k],Bin)
    for i in 1:n;JuMP.@constraint(model,sum(x[i,j] for j in 1:k)==1);end
    for (j,g) in enumerate(labels)
        JuMP.@constraint(model,sum(x[i,j] for i in 1:n)==length(reference[g]))
        if g in inland
            for i in coast;JuMP.fix(x[i,j],0;force=true);end
        else
            JuMP.@constraint(model,sum(x[i,j] for i in coast)>=1)
        end
    end
    JuMP.@objective(model,Min,sum(costs[i,j]*x[i,j] for i in 1:n,j in 1:k))
    attempts=NamedTuple[]
    for iteration in 1:rounds
        JuMP.optimize!(model)
        feasible=JuMP.has_values(model)
        println("Regional seed $iteration: ",JuMP.termination_status(model)," feasible=",feasible);flush(stdout)
        push!(attempts,(iteration=iteration,status=string(JuMP.termination_status(model)),feasible=feasible))
        feasible || return nothing,(complete=false,attempts=attempts)
        result=Dict(g=>Set(points[i] for i in 1:n if JuMP.value(x[i,j])>.5) for (j,g) in enumerate(labels))
        broken=false
        for (j,g) in enumerate(labels)
            components=connected_parts(result[g];diagonals=true)
            length(components)<=1 && continue
            broken=true
            for component in components
                boundary=Set((p[1]+dx,p[2]+dy) for p in component for (dx,dy) in CORNER_OFFSETS if (p[1]+dx,p[2]+dy) ∉ component && haskey(lookup,(p[1]+dx,p[2]+dy)))
                # This component is smaller than the country's fixed budget.
                # If any of it remains, a connected country must cross its boundary.
                JuMP.@constraint(model,sum(x[lookup[p],j] for p in component)<=length(component)*sum(x[lookup[q],j] for q in boundary))
            end
        end
        broken && continue
        all(length(result[g])==length(reference[g]) for g in labels) || error("Seed budget mismatch")
        return result,(complete=true,method="geographic region seed",attempts=attempts)
    end
    nothing,(complete=false,attempts=attempts)
end
