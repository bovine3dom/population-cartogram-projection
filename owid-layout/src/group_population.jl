const EDGE_OFFSETS = ((-1,0),(1,0),(0,-1),(0,1))
const CORNER_OFFSETS = (EDGE_OFFSETS...,(-1,-1),(-1,1),(1,-1),(1,1))

function describe_cells(id, cells)
    points=sort!(collect(cells))
    Piece(id,length(points),ntuple(a->sum(p[a] for p in points)/length(points),2),
          (minimum(first,points)-.5,minimum(last,points)-.5,maximum(first,points)+.5,maximum(last,points)+.5))
end

"""Largest remainders with explicit visibility floors and stable ID ordering."""
function allocate_tiles(masses, total; floors=ones(Int,length(masses)))
    length(masses)==length(floors) && !isempty(masses) || throw(ArgumentError("Invalid allocation inputs"))
    isfinite(total) && total>=1 && isinteger(total) || throw(ArgumentError("Need a positive integer tile count"))
    total=Int(total)
    all(p->isfinite(p)&&p>0,masses) || throw(ArgumentError("Need positive finite populations"))
    all(n->n>=1&&isinteger(n),floors) && sum(floors)<=total || throw(ArgumentError("Infeasible visibility floors"))
    result=zeros(Int,length(masses)); active=collect(eachindex(masses))
    while !isempty(active)
        remaining=total-sum(result); mass=sum(masses[i] for i in active)
        quotas=Dict(i=>remaining*masses[i]/mass for i in active)
        low=[i for i in active if quotas[i]<floors[i]]
        if !isempty(low)
            for i in low; result[i]=floors[i]; end
            filter!(i->i ∉ low,active)
        else
            for i in active; result[i]=floor(Int,quotas[i]); end
            order=sort(active;by=i->(-(quotas[i]-result[i]),i))
            for i in order[1:total-sum(result)]; result[i]+=1; end
            break
        end
    end
    result
end

# Shared Natural Earth segments supply border evidence. Round coordinates only
# for segment identity, not geometry or population. Missing evidence is not a veto.
function source_neighbours(features, scopes)
    edges=Dict{Tuple{NTuple{2,Float64},NTuple{2,Float64}},Vector{String}}()
    for f in features
        id=String(f["properties"]["component_id"])
        haskey(scopes,id) || continue
        g=f["geometry"]; polygons=g["type"]=="Polygon" ? [g["coordinates"]] : g["coordinates"]
        for polygon in polygons, ring in polygon, i in 1:length(ring)-1
            a=Tuple(round.(Float64.(ring[i]);digits=7)); b=Tuple(round.(Float64.(ring[i+1]);digits=7))
            a==b && continue
            push!(get!(edges,minmax(a,b),String[]),id)
        end
    end
    neighbours=Dict(id=>Set{String}() for id in keys(scopes))
    for ids in values(edges)
        length(ids)>1 || continue
        for a in ids,b in ids
            scopes[a]==scopes[b] && continue
            push!(neighbours[a],scopes[b])
        end
    end
    neighbours
end

function local_rings(geometry, lon, lat)
    polygons=geometry["type"]=="Polygon" ? [geometry["coordinates"]] : geometry["coordinates"]
    [[[(mod(Float64(p[1])-lon+180,360)-180,Float64(p[2])-lat) for p in ring] for ring in poly] for poly in polygons]
end

function point_in_ring(point,ring)
    x,y=point; inside=false
    for i in eachindex(ring)
        a=ring[i]; b=ring[mod1(i+1,length(ring))]
        if (a[2]>y)!=(b[2]>y) && x<(b[1]-a[1])*(y-a[2])/(b[2]-a[2])+a[1]
            inside=!inside
        end
    end
    inside
end

function point_geometry_distance(point,polygons,latitude)
    any(poly->point_in_ring(point,first(poly))&&!any(r->point_in_ring(point,r),poly[2:end]),polygons) && return 0.0
    factor=cosd(latitude); distance=Inf
    for poly in polygons,ring in poly,i in eachindex(ring)
        a=ring[i]; b=ring[mod1(i+1,length(ring))]
        dx,dy=(b[1]-a[1])*factor,b[2]-a[2]
        px,py=(point[1]-a[1])*factor,point[2]-a[2]
        length2=dx*dx+dy*dy
        t=length2==0 ? 0.0 : clamp((px*dx+py*dy)/length2,0,1)
        distance=min(distance,hypot(px-t*dx,py-t*dy))
    end
    distance
end

"""Match group anchors automatically, then assign every source to one group.

A group can receive many source components. Distances for the fallback are
source-centroid to source-polygon distances in a local latitude-corrected plane.
They are not full geometry-to-geometry or geodesic distances.
"""
function match_group_population(sources, targets, geometry, source_rows, total;
                                target_neighbours=Dict(), source_neighbours=Dict(), floors=Dict(),
                                children=Piece[], membership=Dict(), target_cells=Dict())
    s=sort(collect(sources);by=p->p.id); t=sort(collect(targets);by=p->p.id)
    if length(t)==1
        g=only(t).id;mass=sum(p.mass for p in s)
        n=only(allocate_tiles([mass],total;floors=[get(floors,g,1)]))
        assignments=[(component_id=p.id,group_id=g,population=p.mass,assignment="whole_scope_group",source_distance=NaN) for p in s]
        groups=[(group_id=g,population_group=g,anchor_components="",pool_population=mass,tiles=n,
                 pool_proportional_tiles=Float64(total),pool_source_components=length(s),identity="whole_scope_group")]
        return (;budgets=Dict(g=>n),assignments,groups)
    end
    anchor=first(sort(s;by=p->(-p.mass,p.id))); r=source_rows[anchor.id]
    lon=(parse(Float64,r.west)+parse(Float64,r.east))/2
    lat=(parse(Float64,r.south)+parse(Float64,r.north))/2
    known=union(Set{String}(),values(source_neighbours)...)
    allowed=(a,b)->issubset(intersect(get(target_neighbours,a.id,Set{String}()),known),get(source_neighbours,b.id,Set{String}()))
    population=Dict(p.id=>p.mass for p in s); source_total=sum(values(population))
    assigned=Dict{String,String}()
    function accept(matches, target_list, parent)
        for row in sort(matches;by=r->(isfinite(r.cost) ? r.cost : Inf,r.target_id))
            isempty(row.source_id) && continue
            p=only(p for p in target_list if p.id==row.target_id)
            unique_border=count(q->allowed(p,q),s)==1
            # Tiny or weak candidates are not forced to own a visible group.
            if length(t)==1 || unique_border || (row.position_cost+.035*row.population_cost<=.12 && population[row.source_id]/source_total*total>=.5)
                get!(assigned,row.source_id,get(parent,row.target_id,row.target_id))
            end
        end
    end
    initial=match_identities(s,t;allowed,allow_unmatched=true)
    # Nearby small islands follow a larger matched outline, not a country-wide
    # affine fit. This is a geometric rule; it contains no island identities.
    large=[r for r in initial if !isempty(r.source_id) && population[r.source_id]>=.02source_total &&
           only(p.mass for p in t if p.id==r.target_id)>=.02total && r.position_cost+.035r.population_cost<=.12]
    mapped=Dict{String,NTuple{2,Float64}}()
    for p in s
        any(r->r.source_id==p.id,large) && continue
        eligible=[r for r in large if population[r.source_id]>=4p.mass]
        isempty(eligible) && continue
        distances=Dict(r.source_id=>point_geometry_distance(p.centre,local_rings(geometry[r.source_id],lon,lat),lat) for r in eligible)
        r=first(sort(eligible;by=r->(distances[r.source_id],r.source_id)))
        b=only(q.bounds for q in s if q.id==r.source_id)
        distances[r.source_id]<=.25sqrt((b[3]-b[1])*(b[4]-b[2])*cosd(lat)) || continue
        tb=only(q.bounds for q in t if q.id==r.target_id)
        mapped[p.id]=ntuple(k->begin
            relative=(p.centre[k]-b[k])/max(b[k+2]-b[k],1e-6)
            inside=clamp(relative,0,1); outside=relative-inside
            tb[k]+(inside+sign(outside)*log1p(abs(outside)))*(tb[k+2]-tb[k])
        end,2)
    end
    accept(match_identities(s,t;allowed,allow_unmatched=true,mapped_centres=mapped),t,Dict())
    # Children supply extra evidence, not independent tile budgets. This lets a
    # corner-connected archipelago retain several source islands as anchors.
    if length(t)>1 && !isempty(children)
        accept(match_identities(s,children;allowed,allow_unmatched=true,mapped_centres=mapped),children,membership)
    end
    isempty(assigned) && throw(ArgumentError("No sufficiently supported group anchors"))
    roots=sort!(unique(collect(values(assigned))))
    shapes=Dict(id=>local_rings(geometry[id],lon,lat) for id in keys(assigned))
    function target_distance(a,b)
        if haskey(target_cells,a.id) && haskey(target_cells,b.id)
            return minimum((p[1]-q[1])^2+(p[2]-q[2])^2 for p in target_cells[a.id],q in target_cells[b.id])
        end
        sum(max(a.bounds[k]-b.bounds[k+2],b.bounds[k]-a.bounds[k+2],0)^2 for k in 1:2)
    end
    parent=Dict(p.id=>(p.id in roots ? p.id : first(sort([q for q in t if q.id in roots];by=q->(target_distance(p,q),q.id))).id) for p in t)
    rows=NamedTuple[]
    for p in s
        direct=haskey(assigned,p.id)
        nearest=direct ? p.id : first(sort!(collect(keys(assigned));by=id->(point_geometry_distance(p.centre,shapes[id],lat),id)))
        push!(rows,(component_id=p.id,group_id=assigned[nearest],population=p.mass,
                    assignment=direct ? "automatic_group_anchor" : "nearest_source_anchor",
                    source_distance=direct ? 0.0 : point_geometry_distance(p.centre,shapes[nearest],lat)))
    end
    masses=Dict(g=>sum(r.population for r in rows if r.group_id==g) for g in roots)
    root_counts=allocate_tiles([masses[g] for g in roots],total;
        floors=[sum(get(floors,p.id,1) for p in t if parent[p.id]==g) for g in roots])
    budgets=Dict{String,Int}(); report=NamedTuple[]
    for (g,n) in zip(roots,root_counts)
        members=[p for p in t if parent[p.id]==g]
        counts=allocate_tiles(getproperty.(members,:mass),n;floors=[get(floors,p.id,1) for p in members])
        anchors=sort!([id for (id,group) in assigned if group==g])
        for (p,ntiles) in zip(members,counts)
            budgets[p.id]=ntiles
            push!(report,(group_id=p.id,population_group=g,anchor_components=join(anchors,";"),
                pool_population=masses[g],tiles=ntiles,pool_proportional_tiles=total*masses[g]/source_total,
                pool_source_components=count(r->r.group_id==g,rows),identity=p.id==g ? "automatic_group" : "nearest_target_group"))
        end
    end
    (;budgets,assignments=rows,groups=sort!(report;by=r->r.group_id))
end
