using OWIDLayout, CSV, JSON
include("../research/mainland/load.jl")
const O=OWIDLayout
length(ARGS)==2 || error("Usage: slide-west-africa.jl CLEAN_BUILD OUTPUT_DIR")
root,output=ARGS
ispath(output) && error("Use a new output directory")
input=joinpath(root,"layout/cells.csv")
owner=Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(input))
mover,receiver="BFA:G1","NGA:G1"
a=Set(p for (p,g) in owner if g==mover);b=Set(p for (p,g) in owner if g==receiver)
width=maximum(first,a)-minimum(first,a)+1;height=maximum(last,a)-minimum(last,a)+1
minimum_block=ceil(Int,.8length(a))
function apply(result)
    after=copy(owner)
    for p in result.moving;after[p]=mover;end
    for p in result.receiving;after[p]=receiver;end
    after
end
function neighbours(after,g)
    sort!(unique([O.group_scope(h) for (p,c) in after if c==g for (dx,dy) in O.EDGE_OFFSETS
        for h in [get(after,(p[1]+dx,p[2]+dy),g)] if h!=g]))
end
function row(dx,dy,r)
    # Other countries are stationary. Ghana is the southern reference for this
    # named two-country demonstration, not a rule for the world layout builder.
    ghana=any(get(owner,(p[1]+sx,p[2]+sy),"")=="GHA:G1" for p in r.moving for (sx,sy) in O.EDGE_OFFSETS)
    (;dx,dy,counter_dx=r.counter_shift[1],counter_dy=r.counter_shift[2],
      counter_tiles=length(r.displaced),counter_rigid_tiles=r.counter_rigid_tiles,
      seam_tiles=r.seam_tiles,overlap_tiles=r.overlap_tiles,touches_ghana=ghana)
end
candidates=NamedTuple[]
for dx in -width:width,dy in -2height:-1
    r=try
        O.slide_exchange(a,b,(dx,dy))
    catch error
        error isa ArgumentError || rethrow()
        continue
    end
    length(r.displaced)>=minimum_block || continue
    push!(candidates,row(dx,dy,r))
end
sort!(candidates;by=r->(r.dx,r.dy))
exact=sort([r for r in candidates if r.seam_tiles==0];by=r->(r.dx^2+r.dy^2,abs(r.dx),r.dx,r.dy))
near=sort([r for r in candidates if r.touches_ghana && r.seam_tiles<=.05r.counter_tiles];
          by=r->(abs(r.dx),r.seam_tiles/r.counter_tiles,r.dx^2+r.dy^2,r.dx,r.dy))
isempty(exact) && error("No large rigid counterblock fits")
isempty(near) && error("No small-seam move reaches Ghana")
mkpath(output)
CSV.write(joinpath(output,"candidates.csv"),candidates)
cp(input,joinpath(output,"before.csv"))
paths=[input,@__FILE__,joinpath(@__DIR__,"../research/mainland/block_slide.jl")]
report=Dict("complete"=>true,"approved"=>false,"method"=>"rigid translation with a counter-moving block",
    "inputs"=>Dict(p=>O.file_digest(p) for p in paths),"minimum_counterblock_tiles"=>minimum_block,
    "search"=>Dict("dx"=>[-width,width],"dy"=>[-2height,-1],"valid_large_block_candidates"=>length(candidates)),
    "limits"=>["Only Burkina Faso and Nigeria can change.","The selected Nigerian block comes from the western arm; it is not a rigid translation of all Nigeria.","No neighbour graph is enforced and this does not repair all geographic relationships."],"variants"=>Dict())
perimeter(ps)=sum((p[1]+dx,p[2]+dy) ∉ ps for p in ps for (dx,dy) in O.EDGE_OFFSETS)
for (name,choice) in (("rigid-swap",first(exact)),("south-slide",first(near)))
    r=O.slide_exchange(a,b,(choice.dx,choice.dy));after=apply(r)
    @assert Set(keys(after))==Set(keys(owner))
    @assert all(after[p]==g for (p,g) in owner if g ∉ (mover,receiver))
    @assert count(==(mover),values(after))==length(a) && count(==(receiver),values(after))==length(b)
    dir=joinpath(output,name);mkdir(dir)
    CSV.write(joinpath(dir,"cells.csv"),[(component_id=g,x=p[1],y=p[2]) for (p,g) in sort!(collect(after);by=first)])
    CSV.write(joinpath(dir,"motions.csv"),r.motions)
    checks=Dict("selection"=>choice,"mover"=>mover,"receiver"=>receiver,
        "moving_shape_exact"=>r.moving==Set((p[1]+choice.dx,p[2]+choice.dy) for p in a),
        "counterblock_shape_exact"=>r.seam_tiles==0,
        "country_counts_exact"=>true,"other_countries_unchanged"=>true,"land_mask_unchanged"=>true,
        "edge_connected"=>true,"moving_tiles"=>length(a),"receiver_tiles"=>length(b),
        "receiver_stationary_tiles"=>length(b)-length(r.displaced),
        "changed_owner_cells"=>count(after[p]!=g for (p,g) in owner),
        "perimeters_before"=>Dict(mover=>perimeter(a),receiver=>perimeter(b)),
        "perimeters_after"=>Dict(mover=>perimeter(r.moving),receiver=>perimeter(r.receiving)),
        "neighbours_before"=>Dict(g=>neighbours(owner,g) for g in (mover,receiver)),
        "neighbours_after"=>Dict(g=>neighbours(after,g) for g in (mover,receiver)))
    report["variants"][name]=checks
    println(name,": ",JSON.json(choice))
end
open(io->JSON.print(io,report),joinpath(output,"report.json"),"w")
println("Wrote ",output)
