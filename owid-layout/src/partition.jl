import JuMP, HiGHS

"""Partition a fixed footprint with exact budgets, contacts, and connectivity.

Variable order, solver threads, seed, node budget, and cut rounds are fixed.
No wall-clock cutoff is used. A feasible incumbent must pass the same checks.
"""
function partition_groups(reference,footprint,budgets; required=nothing,outside=Dict(),
                          preferred=reference,inland=nothing,radius=3.,node_limit=100_000,rounds=80,
                          perimeter_weight=.25,cell_costs=nothing,free_outside_contacts=false,
                          contact_penalty=nothing,start_reference=false)
    labels=sort!(collect(keys(reference)));points=sort!(collect(footprint))
    Set(labels)==Set(keys(budgets)) || error("Partition budget labels differ")
    sum(values(budgets))==length(points) || error("Partition count differs from footprint")
    all(n->n>=1&&isinteger(n),values(budgets)) || error("Invalid partition budget")
    isempty(intersect(Set(keys(outside)),Set(points))) || error("Footprint overlaps outside land")
    old=merge(copy(outside),group_owners(reference))
    required=isnothing(required) ? edge_contacts(old) : required
    n=length(points);k=length(labels);lookup=Dict(p=>i for (i,p) in enumerate(points))
    centroid=cell_centre(Set(p for ps in values(reference) for p in ps));scale=sqrt(n/sum(length,values(reference)))
    guide=Dict(g=>[ntuple(a->centroid[a]+scale*(p[a]-centroid[a]),2) for p in preferred[g]] for g in labels)
    distances=isnothing(cell_costs) ? [minimum(sum((p[a]-q[a])^2 for a in 1:2) for q in guide[g]) for p in points,g in labels] : cell_costs
    size(distances)==(n,k) && all(isfinite,distances) || error("Invalid cell costs")
    isfinite(perimeter_weight) && perimeter_weight>=0 || error("Invalid perimeter weight")
    free_outside_contacts && any(!all(g in labels for g in pair) for pair in required) && error("Free outside contacts require an internal-only graph")
    allowed=distances .<= minimum(distances;dims=2) .+ radius^2
    # Increase candidates deterministically if a label has too little capacity.
    for j in 1:k
        if count(allowed[:,j])<budgets[labels[j]]
            order=sortperm(1:n;by=i->(distances[i,j],i))
            allowed[order[1:budgets[labels[j]]],j].=true
        end
    end
    soft=!isnothing(contact_penalty)
    soft && !(isfinite(contact_penalty)&&contact_penalty>0) && error("Invalid contact penalty")
    if start_reference
        Set(points)==Set(p for ps in values(reference) for p in ps) || error("Reference start requires the same footprint")
        for (j,g) in enumerate(labels),p in reference[g];allowed[lookup[p],j]=true;end
    end
    model=JuMP.Model(HiGHS.Optimizer);JuMP.set_silent(model)
    for (name,value) in (("threads",1),("random_seed",0),("parallel","off"),("mip_max_nodes",node_limit),("mip_rel_gap",0.002))
        JuMP.set_optimizer_attribute(model,name,value)
    end
    JuMP.@variable(model,x[1:n,1:k],Bin)
    for i in 1:n,j in 1:k
        allowed[i,j] || JuMP.fix(x[i,j],0;force=true)
        start_reference && JuMP.set_start_value(x[i,j],points[i] in reference[labels[j]] ? 1. : 0.)
    end
    for i in 1:n;JuMP.@constraint(model,sum(x[i,j] for j in 1:k)==1);end
    for j in 1:k;JuMP.@constraint(model,sum(x[i,j] for i in 1:n)==budgets[labels[j]]);end
    objective=JuMP.@expression(model,sum(distances[i,j]*x[i,j] for i in 1:n,j in 1:k if allowed[i,j]))
    witnesses=Dict(pair=>JuMP.VariableRef[] for pair in required)
    witnessed=Set{Tuple{String,String}}()
    for (p,g) in outside,(dx,dy) in ((1,0),(0,1))
        q=(p[1]+dx,p[2]+dy)
        haskey(outside,q) && outside[q]!=g && push!(witnessed,minmax(g,outside[q]))
    end
    for (i,p) in enumerate(points),(dx,dy) in EDGE_OFFSETS
        q=(p[1]+dx,p[2]+dy)
        if haskey(lookup,q)
            h=lookup[q];i<h || continue
            for a in 1:k,b in 1:k
                a==b || !allowed[i,a] || !allowed[h,b] || begin
                    pair=minmax(labels[a],labels[b])
                    if pair ∉ required
                        if soft
                            violation=JuMP.@variable(model,lower_bound=0)
                            JuMP.@constraint(model,violation>=x[i,a]+x[h,b]-1)
                            JuMP.add_to_expression!(objective,contact_penalty,violation)
                        else
                            JuMP.@constraint(model,x[i,a]+x[h,b]<=1)
                        end
                    else
                        w=JuMP.@variable(model,binary=true)
                        JuMP.@constraint(model,w<=x[i,a]);JuMP.@constraint(model,w<=x[h,b])
                        push!(witnesses[pair],w)
                    end
                end
            end
            for j in 1:k
                allowed[i,j] || allowed[h,j] || continue
                edge=JuMP.@variable(model,lower_bound=0)
                JuMP.@constraint(model,edge>=x[i,j]-x[h,j]);JuMP.@constraint(model,edge>=x[h,j]-x[i,j])
                JuMP.add_to_expression!(objective,perimeter_weight,edge)
            end
        elseif haskey(outside,q) && !free_outside_contacts
            for j in 1:k
                allowed[i,j] || continue
                labels[j]==outside[q] && continue
                pair=minmax(labels[j],outside[q])
                if pair ∉ required
                    JuMP.fix(x[i,j],0;force=true)
                else
                    push!(witnesses[pair],x[i,j])
                end
            end
        end
    end
    for pair in sort!(collect(required))
        pair in witnessed && continue
        if soft
            absent=JuMP.@variable(model,binary=true)
            JuMP.@constraint(model,sum(witnesses[pair])+absent>=1)
            JuMP.add_to_expression!(objective,contact_penalty,absent)
        else
            isempty(witnesses[pair]) && return nothing,(complete=false,reason="No contact witness",contact=pair)
            JuMP.@constraint(model,sum(witnesses[pair])>=1)
        end
    end
    occupied=union(Set(points),Set(keys(outside)));newwater=enclosed_cells(occupied);oldwater=enclosed_cells(keys(old))
    coast=[i for (i,p) in enumerate(points) if any(begin q=(p[1]+dx,p[2]+dy);q ∉ occupied && q ∉ newwater end for (dx,dy) in EDGE_OFFSETS)]
    for (j,g) in enumerate(labels)
        oldcoastal=any(begin q=(p[1]+dx,p[2]+dy);!haskey(old,q) && q ∉ oldwater end for p in reference[g] for (dx,dy) in EDGE_OFFSETS)
        coastal=isnothing(inland) ? oldcoastal : g ∉ inland
        if coastal
            JuMP.@constraint(model,sum(x[i,j] for i in coast)>=1)
        else
            for i in coast;JuMP.fix(x[i,j],0;force=true);end
        end
    end
    JuMP.@objective(model,Min,objective)
    attempts=NamedTuple[]
    for iteration in 1:rounds
        JuMP.optimize!(model)
        push!(attempts,(iteration=iteration,status=string(JuMP.termination_status(model)),feasible=JuMP.has_values(model)))
        JuMP.has_values(model) || return nothing,(complete=false,attempts=attempts)
        result=Dict(g=>Set(points[i] for i in 1:n if JuMP.value(x[i,j])>.5) for (j,g) in enumerate(labels))
        broken=false
        for (j,g) in enumerate(labels)
            components=connected_parts(result[g];diagonals=true)
            length(components)<=1 && continue
            broken=true
            for component in components
                boundary=Set((p[1]+dx,p[2]+dy) for p in component for (dx,dy) in CORNER_OFFSETS if (p[1]+dx,p[2]+dy) ∉ component && haskey(lookup,(p[1]+dx,p[2]+dy)))
                JuMP.@constraint(model,sum(x[lookup[p],j] for p in component)-sum(x[lookup[q],j] for q in boundary)<=length(component)-1)
            end
        end
        broken && continue
        all(length(result[g])==budgets[g] for g in labels) || error("Partition count check failed")
        actual=edge_contacts(merge(copy(outside),group_owners(result)))
        free_outside_contacts && filter!(pair->all(g in labels for g in pair),actual)
        soft || actual==required || error("Partition contact check failed")
        return result,(complete=true,attempts=attempts,variables=JuMP.num_variables(model),node_limit=node_limit,radius=radius,
                       perimeter_weight=perimeter_weight,free_outside_contacts=free_outside_contacts,
                       topology_exact=actual==required,contact_penalty=contact_penalty)
    end
    nothing,(complete=false,attempts=attempts,reason="Connectivity cut limit")
end
