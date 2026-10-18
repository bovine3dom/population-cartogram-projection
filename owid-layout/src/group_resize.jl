group_scope(g)=first(split(g,':'))
cell_centre(cells)=ntuple(k->sum(p[k] for p in sort!(collect(cells)))/length(cells),2)

function group_owners(groups)
    owner=Dict{Tuple{Int,Int},String}()
    for g in sort!(collect(keys(groups))),p in groups[g]
        haskey(owner,p) && throw(ArgumentError("Overlapping group cells"))
        owner[p]=g
    end
    owner
end

function edge_contacts(owner)
    contacts=Set{Tuple{String,String}}()
    for (p,g) in owner,(dx,dy) in ((1,0),(0,1))
        q=(p[1]+dx,p[2]+dy)
        haskey(owner,q) && owner[q]!=g && push!(contacts,minmax(g,owner[q]))
    end
    contacts
end

function enclosed_cells(cells)
    isempty(cells) && return Set{Tuple{Int,Int}}()
    west=minimum(first,cells)-1; east=maximum(first,cells)+1
    south=minimum(last,cells)-1; north=maximum(last,cells)+1
    occupied=Set(cells); seen=Set([(west,south)]); queue=[(west,south)]
    for (x,y) in queue,(dx,dy) in EDGE_OFFSETS
        q=(x+dx,y+dy)
        if west<=q[1]<=east && south<=q[2]<=north && q ∉ occupied && q ∉ seen
            push!(seen,q);push!(queue,q)
        end
    end
    Set((x,y) for x in west:east,y in south:north if (x,y) ∉ occupied && (x,y) ∉ seen)
end

# Eight-connected land and four-connected water are complementary. Reject an
# addition that splits the neighbouring water into two edge-connected regions.
function open_water_add(cells,p)
    empty=Set((p[1]+dx,p[2]+dy) for (dx,dy) in CORNER_OFFSETS if (p[1]+dx,p[2]+dy) ∉ cells)
    sides=Set((p[1]+dx,p[2]+dy) for (dx,dy) in EDGE_OFFSETS)
    count(part->!isempty(intersect(part,sides)),connected_parts(empty))==1
end

function outline_score(reference,count,desired)
    centre=cell_centre(reference); scale=sqrt(count/length(reference))
    edges=Tuple{NTuple{2,Float64},NTuple{2,Float64}}[]
    for p in reference,(dx,dy) in EDGE_OFFSETS
        (p[1]+dx,p[2]+dy) in reference && continue
        a=(p[1]+dx/2-dy/2,p[2]+dy/2+dx/2)
        b=(p[1]+dx/2+dy/2,p[2]+dy/2-dx/2)
        push!(edges,(a,b))
    end
    function score(p)
        q=ntuple(k->centre[k]+(p[k]-desired[k])/scale,2)
        inside=(round(Int,q[1]),round(Int,q[2])) in reference
        distance=minimum(begin
            dx,dy=b[1]-a[1],b[2]-a[2]
            t=clamp((q[1]-a[1])*dx+(q[2]-a[2])*dy,0,1)
            (q[1]-a[1]-t*dx)^2+(q[2]-a[2]-t*dy)^2
        end for (a,b) in edges)
        (inside ? -distance : distance, sum((p[k]-desired[k])^2 for k in 1:2),p)
    end
    score,scale,centre
end

"""Exact-count, corner-connected outline grown towards a scaled OWID guide."""
function scaled_group_outline(reference,count,desired)
    count>=1 || throw(ArgumentError("Need a positive tile count"))
    score,scale,centre=outline_score(reference,count,desired)
    seeds=unique([ntuple(k->round(Int,desired[k]+scale*(p[k]-centre[k])),2) for p in reference])
    seed=first(sort!(seeds;by=p->(score(p)[1]>0,sum((p[k]-desired[k])^2 for k in 1:2),p)))
    shape=Set([seed]); candidates=Set{Tuple{Int,Int}}(); cache=Dict{Tuple{Int,Int},Any}()
    function offer(p)
        for (dx,dy) in CORNER_OFFSETS
            q=(p[1]+dx,p[2]+dy)
            q in shape && continue
            push!(candidates,q);get!(cache,q) do; score(q); end
        end
    end
    offer(seed)
    while length(shape)<count
        choices=sort!(collect(candidates);by=p->cache[p])
        i=findfirst(p->open_water_add(shape,p),choices)
        isnothing(i) && error("No connected outline extension")
        p=choices[i];delete!(candidates,p);push!(shape,p);offer(p)
    end
    length(connected_parts(shape;diagonals=true))==1 || error("Disconnected generated group")
    isempty(enclosed_cells(shape)) || error("Generated outline encloses water")
    shape
end

function resize_attached!(groups,g,count,reference,owner,required,water)
    points=groups[g]; pinned=Set(p for p in points if any(q->q in water || haskey(owner,q)&&owner[q]!=g,
        ((p[1]+dx,p[2]+dy) for (dx,dy) in EDGE_OFFSETS)))
    count>=length(pinned) || return "Budget below protected border/shore cells"
    score,_,_=outline_score(reference,count,cell_centre(points))
    components=length(connected_parts(points;diagonals=true))
    while length(points)!=count
        shrinking=length(points)>count
        candidates=shrinking ? [p for p in points if p ∉ pinned && any((p[1]+dx,p[2]+dy) ∉ points for (dx,dy) in EDGE_OFFSETS)] :
            collect(Set((p[1]+dx,p[2]+dy) for p in points for (dx,dy) in EDGE_OFFSETS if !haskey(owner,(p[1]+dx,p[2]+dy)) && (p[1]+dx,p[2]+dy) ∉ water))
        function edit_cost(p)
            neighbours=sum(d->(p[1]+d[1],p[2]+d[2]) in points,EDGE_OFFSETS)
            perimeter_change=shrinking ? 2neighbours-4 : 4-2neighbours
            ((shrinking ? -score(p)[1] : score(p)[1])+.25perimeter_change,score(p)[2],p)
        end
        sort!(candidates;by=edit_cost)
        accepted=false
        for p in candidates
            if shrinking
                delete!(points,p)
                if isempty(points) || length(connected_parts(points;diagonals=true))>components
                    push!(points,p);continue
                end
                delete!(owner,p)
            else
                any(begin
                    q=(p[1]+dx,p[2]+dy)
                    haskey(owner,q)&&owner[q]!=g&&minmax(g,owner[q]) ∉ required
                end for (dx,dy) in CORNER_OFFSETS) && continue
                open_water_add(keys(owner),p) || continue
                push!(points,p);owner[p]=g
            end
            accepted=true;break
        end
        accepted || return "No coast edit preserves borders, water, and group parts"
    end
    nothing
end

"""Trial resize of new groups. Unchanged groups retain the reviewed geometry."""
function resize_groups(current,reference,budgets;max_shift=24)
    Set(keys(current))==Set(keys(budgets)) || throw(ArgumentError("Missing group budget"))
    all(n->n>=1&&isinteger(n),values(budgets)) || throw(ArgumentError("Invalid budgets"))
    before=group_owners(current); required=edge_contacts(before); water=enclosed_cells(keys(before))
    for scope in unique(group_scope.(collect(keys(current))))
        sum(length(ps) for (g,ps) in current if group_scope(g)==scope)==sum(n for (g,n) in budgets if group_scope(g)==scope) || throw(ArgumentError("Country total changed"))
    end
    groups=deepcopy(current); owner=copy(before)
    changed=sort!([g for (g,ps) in current if length(ps)!=budgets[g]])
    changed_scopes=Set(group_scope.(changed))
    attached=Set(g for pair in required for g in pair)
    movable=sort!([g for g in keys(groups) if g ∉ attached && group_scope(g) in changed_scopes])
    details=Dict{String,Any}("changed_groups"=>changed,"moved_groups"=>Any[],"attached_edits"=>Any[],"water_before"=>length(water))
    for g in sort([g for g in changed if g in attached];by=g->(budgets[g]-length(groups[g])>0,g))
        error=resize_attached!(groups,g,budgets[g],get(reference,g,current[g]),owner,required,water)
        push!(details["attached_edits"],(group_id=g,before=length(current[g]),after=length(groups[g]),error=error))
        isnothing(error) || return nothing,details
    end
    for g in movable,p in groups[g];delete!(owner,p);end
    placed=Dict(g=>cell_centre(ps) for (g,ps) in groups if g ∉ movable)
    desired=Dict(g=>cell_centre(ps) for (g,ps) in current)
    for g in sort(movable;by=g->(-budgets[g],g))
        shape=budgets[g]==length(current[g]) ? copy(current[g]) : scaled_group_outline(reference[g],budgets[g],desired[g])
        centre=cell_centre(shape)
        base=ntuple(k->round(Int,desired[g][k]-centre[k]),2)
        translations=sort!(vec([(base[1]+dx,base[2]+dy) for dx in -max_shift:max_shift,dy in -max_shift:max_shift]);
                           by=d->(sum((centre[k]+d[k]-desired[g][k])^2 for k in 1:2),d))
        accepted=false
        for d in translations
            newcentre=ntuple(k->centre[k]+d[k],2)
            any(begin
                delta=desired[g][k]-desired[h][k]
                abs(delta)>=2 && sign(delta)*(newcentre[k]-c[k])<1
            end for (h,c) in placed if group_scope(h)==group_scope(g) for k in 1:2) && continue
            moved=Set((p[1]+d[1],p[2]+d[2]) for p in shape)
            any(p->p in water || haskey(owner,p) || any(haskey(owner,(p[1]+dx,p[2]+dy)) for (dx,dy) in CORNER_OFFSETS),moved) && continue
            groups[g]=moved
            for p in moved;owner[p]=g;end
            placed[g]=newcentre
            push!(details["moved_groups"],(group_id=g,shift=d,before=length(current[g]),after=length(moved),
                  centre_displacement=ntuple(k->newcentre[k]-desired[g][k],2)))
            accepted=true;break
        end
        if !accepted
            details["blocked_group"]=g;details["reason"]="No collision-free position within movement/order bounds"
            return nothing,details
        end
    end
    final=group_owners(groups); finalwater=enclosed_cells(keys(final))
    details["water_after"]=length(finalwater)
    details["water_unchanged"]=water==finalwater
    details["contacts_unchanged"]=edge_contacts(final)==required
    details["budgets_exact"]=all(length(groups[g])==n for (g,n) in budgets)
    details["total_tiles"]=length(final)
    details["complete"]=details["water_unchanged"]&&details["contacts_unchanged"]&&details["budgets_exact"]&&length(final)==length(before)
    details["complete"] ? (groups,details) : (nothing,details)
end
