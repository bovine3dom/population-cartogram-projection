"""Improve a fixed regional mask with count-preserving exchanges.

This is a local search, not a topology guarantee. Wrong neighbour edges and
missing geographic contacts have explicit costs. Counts, connectivity, and
coast status remain hard constraints. Equal-cost choices use sorted cell IDs.
"""
function exchange_region(reference,outside,required,costs;inland=Set{String}(),contact_penalty=200.,perimeter_weight=2.,sweeps=60)
    groups=deepcopy(reference);owner=merge(copy(outside),group_owners(groups))
    labels=sort!(collect(keys(groups)));footprint=Set(p for ps in values(groups) for p in ps)
    points=sort!(collect(footprint));lookup=Dict(p=>i for (i,p) in enumerate(points));column=Dict(g=>j for (j,g) in enumerate(labels))
    size(costs)==(length(points),length(labels)) || error("Exchange cost dimensions differ")
    water=enclosed_cells(keys(owner))
    coastal=Set(p for p in footprint if any(begin q=(p[1]+dx,p[2]+dy);!haskey(owner,q)&&q ∉ water end for (dx,dy) in EDGE_OFFSETS))
    function edge_counts()
        counts=Dict{Tuple{String,String},Int}()
        for p in points,(dx,dy) in ((1,0),(0,1))
            q=(p[1]+dx,p[2]+dy);q in footprint || continue
            a,b=owner[p],owner[q];a==b && continue
            pair=minmax(a,b);counts[pair]=get(counts,pair,0)+1
        end
        counts
    end
    counts=edge_counts();records=NamedTuple[]
    for sweep in 1:sweeps
        accepted=0;improvement=0.
        pairs=Set(minmax(owner[p],owner[q]) for p in points for (dx,dy) in CORNER_OFFSETS
            for q in [(p[1]+dx,p[2]+dy)] if q in footprint && owner[p]!=owner[q])
        for (a,b) in sort!(collect(pairs))
            frontier(g,h)=sort!([p for p in groups[g] if any(get(owner,(p[1]+dx,p[2]+dy),"")==h for (dx,dy) in CORNER_OFFSETS)])
            candidates=Tuple{Float64,Tuple{Int,Int},Tuple{Int,Int}}[]
            for p in frontier(a,b),q in frontier(b,a)
                (b in inland && p in coastal || a in inland && q in coastal) && continue
                edges=Set(minmax(r,(r[1]+dx,r[2]+dy)) for r in (p,q) for (dx,dy) in EDGE_OFFSETS if (r[1]+dx,r[2]+dy) in footprint)
                newlabel(r)=r==p ? b : r==q ? a : owner[r]
                delta=Dict{Tuple{String,String},Int}()
                for (u,v) in edges
                    x,y=owner[u],owner[v]
                    x==y || (pair=minmax(x,y);delta[pair]=get(delta,pair,0)-1)
                    x,y=newlabel(u),newlabel(v)
                    x==y || (pair=minmax(x,y);delta[pair]=get(delta,pair,0)+1)
                end
                gain=costs[lookup[p],column[b]]-costs[lookup[p],column[a]]+costs[lookup[q],column[a]]-costs[lookup[q],column[b]]
                for (pair,d) in delta
                    gain+=2perimeter_weight*d
                    pair ∉ required && (gain+=contact_penalty*d)
                    if pair in required
                        old=get(counts,pair,0);gain+=contact_penalty*((old+d==0)-(old==0))
                    end
                end
                gain < -1e-8 && push!(candidates,(gain,p,q))
            end
            sort!(candidates)
            for (gain,p,q) in candidates
                delete!(groups[a],p);delete!(groups[b],q);push!(groups[a],q);push!(groups[b],p)
                valid=all(length(connected_parts(groups[g];diagonals=true))==1 &&
                    ((g in inland) ? isempty(intersect(groups[g],coastal)) : !isempty(intersect(groups[g],coastal))) for g in (a,b))
                if valid
                    owner[p]=b;owner[q]=a;counts=edge_counts();accepted+=1;improvement-=gain;break
                end
                delete!(groups[a],q);delete!(groups[b],p);push!(groups[a],p);push!(groups[b],q)
            end
        end
        push!(records,(sweep=sweep,exchanges=accepted,objective_reduction=improvement))
        println("Exchange sweep $sweep: $accepted swaps, objective reduction=$improvement");flush(stdout)
        accepted==0 && break
    end
    all(length(groups[g])==length(reference[g]) for g in labels) || error("Exchange budgets changed")
    groups,(complete=true,method="count-preserving local exchanges",sweeps=records,
            topology_exact=Set(keys(counts))==required,contact_penalty=contact_penalty)
end
