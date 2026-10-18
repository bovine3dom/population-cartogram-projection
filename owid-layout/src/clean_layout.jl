function land_blocks(groups)
    contacts=edge_contacts(group_owners(groups));remaining=Set(keys(groups));blocks=Vector{String}[]
    while !isempty(remaining)
        seed=minimum(remaining);delete!(remaining,seed);block=[seed]
        for g in block,(a,b) in sort!(collect(contacts))
            h=a==g ? b : b==g ? a : ""
            if h in remaining;delete!(remaining,h);push!(block,h);end
        end
        push!(blocks,sort!(block))
    end
    sort!(blocks;by=first)
end

function fit_clean_layout(reference,budgets;node_limit=100_000,max_shift=32)
    original=group_owners(reference);contacts=edge_contacts(original)
    # Only water inside an edge-connected landmass is protected as internal water.
    # Gaps enclosed jointly by separate artwork pieces may open to the sea.
    water=union(Set{Tuple{Int,Int}}(),[enclosed_cells(ps) for ps in connected_parts(keys(original))]...)
    templates=Any[];records=Any[]
    for labels in land_blocks(reference)
        localref=Dict(g=>reference[g] for g in labels);owner=group_owners(localref)
        target=sum(budgets[g] for g in labels);unchanged=all(length(reference[g])==budgets[g] for g in labels)
        fitted=nothing;checks=Any[];method="unchanged"
        if unchanged
            fitted=deepcopy(localref)
        elseif length(labels)==1
            g=only(labels)
            if isempty(intersect(Set(keys(owner)),Set(q for p in water for q in ((p[1]+dx,p[2]+dy) for (dx,dy) in EDGE_OFFSETS))))
                fitted=Dict(g=>scaled_group_outline(reference[g],target,cell_centre(reference[g])))
                method="scaled single-group outline"
            end
        elseif length(owner)<=2000
            footprint=scaled_group_outline(Set(keys(owner)),target,cell_centre(keys(owner)))
            method="shared outline partition"
            for radius in (2.,4.,8.)
                fitted,check=partition_groups(localref,footprint,Dict(g=>budgets[g] for g in labels);radius,node_limit)
                push!(checks,check);fitted!==nothing && break
            end
        end
        if fitted===nothing
            method="local coast edits"
            fitted=deepcopy(localref);working=copy(owner);required=edge_contacts(owner)
            reserve=intersect(water,Set((p[1]+dx,p[2]+dy) for p in keys(owner) for (dx,dy) in EDGE_OFFSETS))
            # Keep at least one existing sea face per coastal label. Preventing
            # new enclosed water then keeps those faces connected to the sea.
            holes=enclosed_cells(keys(owner))
            for g in labels
                sea=Set((p[1]+dx,p[2]+dy) for p in reference[g] for (dx,dy) in EDGE_OFFSETS if !haskey(owner,(p[1]+dx,p[2]+dy)) && (p[1]+dx,p[2]+dy) ∉ holes)
                isempty(sea) || push!(reserve,minimum(sea))
            end
            for g in sort(labels;by=g->(budgets[g]-length(reference[g])>0,g))
                length(fitted[g])==budgets[g] && continue
                reason=resize_attached!(fitted,g,budgets[g],reference[g],working,required,reserve)
                push!(checks,(group_id=g,complete=isnothing(reason),reason=reason))
                if !isnothing(reason);fitted=nothing;break;end
            end
        end
        record=(groups=labels,before=length(owner),after=target,method=method,complete=fitted!==nothing,checks=checks)
        push!(records,record);println("Land block ",first(labels),": ",method," ",record.complete);flush(stdout)
        fitted===nothing && return nothing,Dict("complete"=>false,"blocks"=>records)
        push!(templates,(labels=labels,groups=fitted,desired=cell_centre(keys(owner)),area=target))
    end
    owner=Dict{Tuple{Int,Int},String}();result=Dict{String,Set{Tuple{Int,Int}}}();placements=Any[]
    protected=Set{Tuple{Int,Int}}()
    for template in sort(templates;by=t->(-t.area,first(t.labels)))
        mask=Set(keys(group_owners(template.groups)));centre=cell_centre(mask)
        oldmask=Set(p for g in template.labels for p in reference[g]);lakes=intersect(water,enclosed_cells(oldmask))
        base=ntuple(k->round(Int,template.desired[k]-centre[k]),2)
        options=sort!(vec([(base[1]+dx,base[2]+dy) for dx in -max_shift:max_shift,dy in -max_shift:max_shift]);
                      by=d->(sum((centre[k]+d[k]-template.desired[k])^2 for k in 1:2),d))
        shift=nothing
        for d in options
            moved=Set((p[1]+d[1],p[2]+d[2]) for p in mask)
            any(p->p in protected || haskey(owner,p) || any(haskey(owner,(p[1]+dx,p[2]+dy)) for (dx,dy) in CORNER_OFFSETS),moved) && continue
            movedlakes=Set((p[1]+d[1],p[2]+d[2]) for p in lakes)
            any(p->haskey(owner,p)||p in moved,movedlakes) && continue
            shift=d;union!(protected,movedlakes);break
        end
        isnothing(shift) && return nothing,Dict("complete"=>false,"blocks"=>records,"blocked_placement"=>template.labels)
        for (g,ps) in template.groups
            result[g]=Set((p[1]+shift[1],p[2]+shift[2]) for p in ps)
            for p in result[g];owner[p]=g;end
        end
        push!(placements,(groups=template.labels,shift=shift))
    end
    holes=enclosed_cells(keys(owner))
    function coastal_groups(cells,water)
        Set(g for (p,g) in cells for (dx,dy) in EDGE_OFFSETS
            if !haskey(cells,(p[1]+dx,p[2]+dy)) && (p[1]+dx,p[2]+dy) ∉ water)
    end
    scopes=unique(group_scope.(collect(keys(reference))))
    checks=Dict("complete"=>true,"blocks"=>records,"placements"=>placements,
        "budgets_exact"=>all(length(result[g])==n for (g,n) in budgets),
        "groups_connected"=>all(length(connected_parts(ps;diagonals=true))==1 for ps in values(result)),
        "scope_totals_exact"=>all(sum(length(ps) for (g,ps) in reference if group_scope(g)==s)==sum(length(ps) for (g,ps) in result if group_scope(g)==s) for s in scopes),
        "coastal_groups_unchanged"=>coastal_groups(original,enclosed_cells(keys(original)))==coastal_groups(owner,holes),
        "contacts_unchanged"=>edge_contacts(owner)==contacts,"protected_water_retained"=>issubset(protected,holes),
        "protected_water_cells"=>length(protected),"water_before"=>length(enclosed_cells(keys(original))),"water_after"=>length(holes),
        "water_unchanged"=>enclosed_cells(keys(original))==holes,"total_tiles"=>length(owner),
        "changed_groups"=>sort!([g for g in keys(reference) if length(reference[g])!=budgets[g]]))
    checks["complete"]=all(checks[k] for k in ("budgets_exact","groups_connected","scope_totals_exact","coastal_groups_unchanged","contacts_unchanged","protected_water_retained"))&&length(owner)==length(original)
    checks["complete"] ? (result,checks) : (nothing,checks)
end

function clean_layout(source_dir,owid,output;node_limit=100_000)
    ispath(output) && error("Use a new layout directory")
    mkdir(output)
    codes=code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
    crosswalk=collect(CSV.File(joinpath(@__DIR__,"..","config","scope-crosswalk.csv");types=String))
    mapping=Dict(String(r.source_scope)=>String(r.target_scope) for r in crosswalk)
    rawrows=collect(CSV.File(joinpath(source_dir,"components.csv");types=String))
    canonical=[begin
        scope=haskey(codes,r.map_unit) ? String(r.map_unit) : String(r.country_id)
        scope=get(ALIASES,scope,scope)
        haskey(mapping,scope) ? merge(NamedTuple(r),(country_id=mapping[scope],map_unit=mapping[scope])) : NamedTuple(r)
    end for r in rawrows]
    component_path=joinpath(output,"components.csv");CSV.write(component_path,canonical)
    polygons=joinpath(source_dir,"polygons.geojson")
    sources=read_sources(component_path,polygons,codes)
    source_rows=Dict(String(r.component_id)=>r for r in CSV.File(component_path;types=String))
    features=JSON.parsefile(polygons)["features"]
    geometry=Dict(String(f["properties"]["component_id"])=>f["geometry"] for f in features)
    source_scopes=Dict(p.id=>scope for (scope,ps) in sources for p in ps)
    reverse=Dict(v=>k for (k,v) in codes)
    owners=Dict(p=>get(reverse,c,"OWID_$c") for (p,c) in read_owid_cells(owid))
    owners,splits=split_population_scopes(owners,sources,features,source_scopes,crosswalk;node_limit)
    open(io->JSON.print(io,splits),joinpath(output,"scope-splits.json"),"w")
    owners===nothing && return Dict("complete"=>false,"reason"=>"Scope split failed","scope_splits"=>splits)
    inventory=target_groups(owners);reference=inventory.groups
    members=Dict(r.target_id=>r.group_id for r in inventory.membership)
    neighbours=source_neighbours(features,source_scopes)
    target_neighbours=Dict{String,Set{String}}()
    for parts in (inventory.groups,inventory.pieces)
        owner=group_owners(parts)
        for g in keys(parts);target_neighbours[g]=Set{String}();end
        for (p,g) in owner,(dx,dy) in EDGE_OFFSETS
            q=(p[1]+dx,p[2]+dy);other=get(owner,q,g)
            group_scope(other)==group_scope(g) || push!(target_neighbours[g],group_scope(other))
        end
    end
    scopes=sort!(unique(collect(values(owners))));assignments=NamedTuple[];reports=NamedTuple[];budgets=Dict{String,Int}()
    for scope in scopes
        haskey(sources,scope) || error("No positive source population for $scope")
        groups=sort!([g for g in keys(reference) if group_scope(g)==scope])
        targets=[describe_cells(g,reference[g]) for g in groups]
        children=[describe_cells(g,ps) for (g,ps) in inventory.pieces if group_scope(g)==scope]
        result=match_group_population(sources[scope],targets,geometry,source_rows,sum(p.mass for p in targets);
            target_neighbours,source_neighbours=Dict(p.id=>neighbours[p.id] for p in sources[scope]),
            children,membership=members,target_cells=reference)
        merge!(budgets,result.budgets)
        append!(assignments,[(;country=scope,r...) for r in result.assignments])
        append!(reports,[(;country=scope,before=length(reference[r.group_id]),r...) for r in result.groups])
        println("Matched ",scope,": ",length(groups)," groups");flush(stdout)
    end
    sort!(assignments;by=r->(r.country,r.component_id))
    allunique(r.component_id for r in assignments) || error("Duplicate source assignment")
    sum(r.population for r in assignments)==sum(p.mass for scope in scopes for p in sources[scope]) || error("Assigned population changed")
    unrepresented=[(country=scope,population=sum(p.mass for p in ps)) for (scope,ps) in sort!(collect(sources);by=first) if scope ∉ scopes]
    CSV.write(joinpath(output,"source-scopes-without-tiles.csv"),unrepresented)
    CSV.write(joinpath(output,"source-assignments.csv"),assignments)
    CSV.write(joinpath(output,"budgets.csv"),reports)
    CSV.write(joinpath(output,"membership.csv"),inventory.membership)
    CSV.write(joinpath(output,"before.csv"),[(component_id=g,x=p[1],y=p[2]) for g in sort!(collect(keys(reference))) for p in sort!(collect(reference[g]))])
    fitted,checks=fit_clean_layout(reference,budgets;node_limit)
    totals=Dict(s=>sum(abs(r.tiles-r.before) for r in reports if r.country==s) for s in scopes)
    selected=sort(scopes;by=s->(-totals[s],s))[1:min(16,length(scopes))]
    record=Dict("complete"=>fitted!==nothing,"approved"=>false,"mode"=>"clean","changed_scopes"=>scopes,"review_scopes"=>selected,
        "fit"=>checks,"land_tiles"=>sum(values(budgets)),"groups"=>length(reference),"scope_splits"=>splits,
        "assigned_population"=>sum(r.population for r in assignments),"unrepresented_population"=>sum(r.population for r in unrepresented),
        "limits"=>["Raw-input build; no saved layouts or assignments are read.","Automatic identities and fallback pools still need visual review.",
                    "Original corner-connected groups can differ from the reviewed experiment's child outlines."])
    if fitted!==nothing
        CSV.write(joinpath(output,"cells.csv"),[(component_id=g,x=p[1],y=p[2]) for g in sort!(collect(keys(fitted))) for p in sort!(collect(fitted[g]))])
    end
    open(io->JSON.print(io,record),joinpath(output,"report.json"),"w")
    record
end
