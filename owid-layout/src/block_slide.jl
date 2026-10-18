"""Translate one piece intact and lift the displaced block in the other direction.

Only the two supplied pieces may exchange space. Complete overlapping translation
chains to obtain a tile bijection, rather than grow or shrink either country.
A minority of counter-moving tiles can travel an extra step at the join.
"""
function slide_exchange(moving,receiving,shift;diagonals=false)
    shift!=(0,0) || throw(ArgumentError("A slide needs a nonzero translation"))
    isempty(intersect(moving,receiving)) || throw(ArgumentError("Input pieces overlap"))
    isempty(moving) && throw(ArgumentError("Moving piece is empty"))
    translated=Set((p[1]+shift[1],p[2]+shift[2]) for p in moving)
    issubset(translated,union(moving,receiving)) || throw(ArgumentError("Slide hits another country or empty space"))
    displaced=setdiff(translated,moving);vacated=setdiff(moving,translated)
    receiver=union(setdiff(receiving,displaced),vacated)
    for cells in (translated,receiver,displaced,vacated)
        length(connected_parts(cells;diagonals))==1 || throw(ArgumentError("Slide splits a country or moving block"))
    end
    motions=[(piece="moving",from_x=p[1],from_y=p[2],to_x=p[1]+shift[1],to_y=p[2]+shift[2],steps=1) for p in sort!(collect(moving))]
    for p in sort!(collect(displaced))
        steps=1;q=(p[1]-shift[1],p[2]-shift[2])
        while q in translated
            steps+=1;q=(q[1]-shift[1],q[2]-shift[2])
        end
        q in vacated || error("Translation chain did not end in the vacated piece")
        push!(motions,(piece="receiving",from_x=p[1],from_y=p[2],to_x=q[1],to_y=q[2],steps=steps))
    end
    origins=Set((r.from_x,r.from_y) for r in motions)
    destinations=Set((r.to_x,r.to_y) for r in motions)
    length(destinations)==length(motions) && origins==destinations || error("Slide is not a tile bijection")
    length(receiver)==length(receiving) && union(receiver,translated)==union(receiving,moving) || error("Slide changed counts or footprint")
    step_counts=Dict(k=>count(r->r.piece=="receiving"&&r.steps==k,motions) for k in unique(r.steps for r in motions if r.piece=="receiving"))
    dominant=first(sort!(collect(keys(step_counts));by=k->(-step_counts[k],k)))
    rigid=step_counts[dominant]
    (;moving=translated,receiving=receiver,motions,displaced,vacated,
      counter_shift=(-dominant*shift[1],-dominant*shift[2]),counter_rigid_tiles=rigid,
      seam_tiles=length(displaced)-rigid,overlap_tiles=length(intersect(moving,translated)))
end
