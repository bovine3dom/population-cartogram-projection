function seed_scope(cells,n,guide)
    order=sort!(collect(cells);by=p->(sum((p[k]-guide[k])^2 for k in 1:2),p))
    for firstcell in order
        selected=Set([firstcell]);remaining=setdiff(cells,selected)
        length(connected_parts(remaining;diagonals=true))==1 || continue
        while length(selected)<n
            frontier=Set((p[1]+dx,p[2]+dy) for p in selected for (dx,dy) in CORNER_OFFSETS if (p[1]+dx,p[2]+dy) in remaining)
            accepted=false
            for p in sort!(collect(frontier);by=p->(sum((p[k]-guide[k])^2 for k in 1:2),p))
                delete!(remaining,p)
                if length(connected_parts(remaining;diagonals=true))==1
                    push!(selected,p);accepted=true;break
                end
                push!(remaining,p)
            end
            accepted || break
        end
        length(selected)==n && return remaining,selected
    end
    error("No connected scope seed")
end

function split_population_scopes(owners,sources,features,source_scopes,crosswalk;node_limit=100_000)
    result=copy(owners);records=Any[]
    neighbours=source_neighbours(features,source_scopes)
    source_contacts=Set{Tuple{String,String}}()
    for (id,other) in neighbours,scope in other
        push!(source_contacts,minmax(source_scopes[id],scope))
    end
    ctx=LibGEOS.GEOSContext()
    shapes=Dict{String,Vector{LibGEOS.Polygon}}()
    for f in features
        id=String(f["properties"]["component_id"]);haskey(source_scopes,id) || continue
        rings=[[Float64[p[1],p[2]] for p in ring] for ring in f["geometry"]["coordinates"]]
        push!(get!(shapes,source_scopes[id],LibGEOS.Polygon[]),LibGEOS.Polygon(rings,ctx))
    end
    geography=Dict(scope=>LibGEOS.unaryUnion(LibGEOS.GeometryCollection(ps,ctx)) for (scope,ps) in shapes)
    for pool in sort!(unique(String(r.pool) for r in crosswalk))
        pool in values(result) || continue # A regional cartogram can omit this pool.
        targets=sort!(unique(String(r.target_scope) for r in crosswalk if r.pool==pool))
        missing=[s for s in targets if s ∉ values(result)]
        isempty(missing) && continue
        length(missing)==1 && pool in values(result) || error("Unsupported combined-scope artwork")
        added=only(missing);oldcells=Set(p for (p,c) in result if c==pool)
        masses=[sum(p.mass for p in sources[s]) for s in targets]
        counts=Dict(zip(targets,allocate_tiles(masses,length(oldcells))))
        both=LibGEOS.union(geography[pool],geography[added]);centre=GeoInterface.coordinates(LibGEOS.centroid(geography[added]))
        bounds=(LibGEOS.getXMin(both),LibGEOS.getYMin(both),LibGEOS.getXMax(both),LibGEOS.getYMax(both))
        tb=describe_cells(pool,oldcells).bounds
        guide=ntuple(k->tb[k]+(centre[k]-bounds[k])/max(bounds[k+2]-bounds[k],1e-6)*(tb[k+2]-tb[k]),2)
        kept,new=seed_scope(oldcells,counts[added],guide)
        before_contacts=edge_contacts(result)
        local_scopes=Set([pool,added])
        for (a,b) in union(before_contacts,source_contacts)
            a in targets && b in values(result) && push!(local_scopes,b)
            b in targets && a in values(result) && push!(local_scopes,a)
        end
        reference=Dict(s=>Set(p for (p,c) in result if c==s) for s in local_scopes if s!=added)
        reference[pool]=kept;reference[added]=new
        budgets=Dict(s=>length(ps) for (s,ps) in reference)
        footprint=Set(p for ps in values(reference) for p in ps)
        outside=Dict(p=>c for (p,c) in result if p ∉ footprint)
        expected=Set(pair for pair in before_contacts if !(pair[1] in local_scopes && pair[2] in local_scopes))
        union!(expected,Set(pair for pair in source_contacts if pair[1] in local_scopes && pair[2] in local_scopes))
        oldwater=enclosed_cells(keys(result))
        inland=Set(s for s in keys(reference) if s!=added && !any(begin q=(p[1]+dx,p[2]+dy);!haskey(result,q)&&q ∉ oldwater end for p in reference[s] for (dx,dy) in EDGE_OFFSETS))
        adjacent=[s for s in keys(geography) if s!=added && minmax(s,added) in source_contacts]
        if !isempty(adjacent)
            others=LibGEOS.unaryUnion(LibGEOS.GeometryCollection([geography[s] for s in sort(adjacent)],ctx))
            coast=LibGEOS.difference(LibGEOS.boundary(geography[added]),LibGEOS.buffer(others,1e-7))
            LibGEOS.geomLength(coast)<1e-5 && push!(inland,added)
        end
        fitted=nothing;attempts=Any[]
        for radius in (2.,4.,8.)
            fitted,check=partition_groups(reference,footprint,budgets;required=expected,outside,inland,radius,node_limit)
            push!(attempts,check);fitted!==nothing && break
        end
        push!(records,(pool=pool,targets=counts,complete=fitted!==nothing,attempts=attempts))
        fitted===nothing && return nothing,records
        result=merge(outside,group_owners(fitted))
        Set(keys(result))==Set(keys(owners)) || error("Scope split changed the land mask")
    end
    result,records
end
