"""Balance sparse transport inside one declared population pool.

The source margin is exact to floating-point precision. The target margin must
pass the tolerance. Failure is an error, not a usable mapping.
"""
function balance_mapping(raw, sources, targets; tolerance=1e-6, iterations=20_000, expansion_steps=4)
    isfinite(tolerance) && 0<tolerance<=1e-4 || error("Invalid balance tolerance")
    iterations>0 && expansion_steps>=0 || error("Invalid balance limits")
    si=Dict(id=>i for (i,id) in enumerate(sources.id))
    ti=Dict((r.x,r.y)=>i for (i,r) in enumerate(eachrow(targets)))
    supply=Float64.(sources.value);demand=sum(supply)/nrow(targets)
    edges=Dict{Tuple{Int,Int},Float64}()
    for r in eachrow(raw)
        isfinite(r.weight) && r.weight>=0 || error("Invalid transport weight")
        r.weight==0 && continue
        i=si[r.id];j=ti[(r.x,r.y)]
        sources.group_id[i]==targets.group_id[j] || error("Transport crosses population pools")
        haskey(edges,(i,j)) && error("Duplicate transport row")
        edges[i,j]=r.weight*supply[i]
    end
    initial_edges=length(edges);error_value=Inf
    for step in 0:expansion_steps
        order=sort!(collect(keys(edges)));rows=first.(order);columns=last.(order)
        mass=[edges[k] for k in order]
        st=zeros(length(supply));tt=zeros(nrow(targets))
        for turn in 1:iterations
            fill!(tt,0.)
            for k in eachindex(mass);tt[columns[k]]+=mass[k];end
            all(>(0),tt) || break
            fill!(st,0.)
            for k in eachindex(mass)
                mass[k]*=demand/tt[columns[k]];st[rows[k]]+=mass[k]
            end
            all(>(0),st) || break
            fill!(tt,0.)
            for k in eachindex(mass)
                mass[k]*=supply[rows[k]]/st[rows[k]];tt[columns[k]]+=mass[k]
            end
            all(isfinite,mass) || error("Non-finite balanced mass")
            error_value=maximum(abs.(tt./demand.-1))
            if error_value<=tolerance
                mapping=DataFrame([(id=sources.id[i],x=targets.x[j],y=targets.y[j],
                    weight=mass[k]/supply[i],weight_mean=mass[k]/tt[j]) for (k,(i,j)) in enumerate(order)])
                return mapping,Dict("maximum_relative_target_error"=>error_value,"balance_iterations"=>turn,
                    "expansion_steps"=>step,"added_pairs"=>length(edges)-initial_edges)
            end
        end
        step==expansion_steps && break
        # Add support, not population. Expansion never leaves this pool.
        added=Set{Tuple{Int,Int}}()
        for (i,j) in keys(edges),(dx,dy) in EDGE_OFFSETS
            k=get(ti,(targets.x[j]+dx,targets.y[j]+dy),0)
            k>0 && sources.group_id[i]==targets.group_id[k] && !haskey(edges,(i,k)) && push!(added,(i,k))
        end
        isempty(added) && break
        for (i,j) in sort!(collect(added));edges[i,j]=supply[i]*1e-3;end
    end
    error("Sparse balance failed; target error=$error_value. No mapping was accepted.")
end

function check_mapping(mapping,sources,targets; tolerance=1e-6)
    PopulationCartogramProjection._validate_inputs(targets,sources)
    source=Dict(r.id=>r for r in eachrow(sources))
    target=Dict((r.x,r.y)=>r for r in eachrow(targets))
    retained=Dict(id=>0.0 for id in keys(source));mass=Dict(p=>0.0 for p in keys(target))
    means=copy(mass);poolmass=Dict{String,Float64}();pooltiles=Dict{String,Int}()
    for r in eachrow(sources);poolmass[r.group_id]=get(poolmass,r.group_id,0.)+r.value;end
    for r in eachrow(targets);pooltiles[r.group_id]=get(pooltiles,r.group_id,0)+1;end
    allunique(zip(mapping.id,mapping.x,mapping.y)) || error("Duplicate mapping rows")
    for r in eachrow(mapping)
        s=source[r.id];p=(r.x,r.y);t=target[p]
        s.group_id==t.group_id || error("Transport crosses population pools")
        isfinite(r.weight) && r.weight>0 && isfinite(r.weight_mean) && r.weight_mean>0 || error("Invalid mapping weights")
        retained[r.id]+=r.weight;mass[p]+=r.weight*s.value;means[p]+=r.weight_mean
    end
    all(isapprox(v,1.;atol=1e-9,rtol=0) for v in values(retained)) || error("Source population was lost")
    all(isapprox(v,1.;atol=1e-9,rtol=0) for v in values(means)) || error("Target mean weights are not normalized")
    for r in eachrow(mapping)
        isapprox(r.weight_mean,r.weight*source[r.id].value/mass[r.x,r.y];rtol=1e-9) || error("Incorrect mean weight")
    end
    target_error=maximum(abs(mass[p]/(poolmass[t.group_id]/pooltiles[t.group_id])-1) for (p,t) in target)
    target_error<=tolerance || error("Target population is not balanced")
    Dict{String,Any}("cross_pool_population"=>0.,"population"=>sum(values(mass)),"tiles"=>length(target),
        "maximum_relative_target_error"=>target_error,"minimum_source_retained_share"=>minimum(values(retained)),
        "maximum_source_retained_share"=>maximum(values(retained)))
end

function fit_pool(sources,targets;backend=KA.CPU(),kwargs...)
    PopulationCartogramProjection._validate_inputs(targets,sources)
    length(unique(sources.group_id))==1 && Set(sources.group_id)==Set(targets.group_id) || error("Expected one population pool")
    if nrow(sources)==1 || nrow(targets)==1
        mapping=DataFrame([(id=s.id,x=t.x,y=t.y,weight=1/nrow(targets),weight_mean=s.value/sum(sources.value))
            for s in eachrow(sources) for t in eachrow(targets)])
        balance=Dict("expansion_steps"=>0,"added_pairs"=>0,"balance_iterations"=>0)
    else
        screen=select(targets,:x,:y);screen.y .*= -1
        raw=PopulationCartogramProjection.distribute(screen,select(sources,:x,:y,:value,:id);backend)
        raw.y .*= -1
        mapping,balance=balance_mapping(raw,sources,targets;kwargs...)
    end
    mapping,merge(balance,check_mapping(mapping,sources,targets))
end
