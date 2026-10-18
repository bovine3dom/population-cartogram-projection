"""Group same-scope artwork by edge or corner contact; keep edge-connected children.

G IDs identify artwork groups, not single geographic islands. T IDs retain the
original edge-connected numbering. Corner joins are not international borders.
"""
function target_groups(owners)
    pieces = Dict{String,Set{Tuple{Int,Int}}}()
    groups = Dict{String,Set{Tuple{Int,Int}}}()
    membership = NamedTuple[]
    piece_owner = Dict{Tuple{Int,Int},String}()
    for scope in sort!(unique(collect(values(owners))))
        cells = [p for (p,c) in owners if c==scope]
        children = connected_parts(cells)
        joined = connected_parts(cells;diagonals=true)
        group_owner = Dict(p=>i for (i,points) in enumerate(joined) for p in points)
        for (i,points) in enumerate(joined)
            groups["$scope:G$i"] = points
        end
        for (i,points) in enumerate(children)
            id = "$scope:T$i"; group = "$scope:G$(group_owner[minimum(points)])"
            pieces[id] = points
            for p in points
                piece_owner[p] = id
            end
            push!(membership,(;scope,target_id=id,group_id=group,tiles=length(points)))
        end
    end
    joins = NamedTuple[]
    for p in sort!(collect(keys(owners)))
        for (dx,dy) in ((1,-1),(1,1))
            q = (p[1]+dx,p[2]+dy)
            if get(owners,q,nothing)==owners[p] && piece_owner[p]!=piece_owner[q]
                push!(joins,(;scope=owners[p],a=piece_owner[p],b=piece_owner[q],x=p[1],y=p[2],qx=q[1],qy=q[2]))
            end
        end
    end
    (;pieces,groups,membership,joins)
end

function read_target_groups(path, codes)
    reverse = Dict(v=>k for (k,v) in codes)
    owners = Dict(p=>get(reverse,c,"OWID_$c") for (p,c) in read_owid_cells(path))
    target_groups(owners)
end
