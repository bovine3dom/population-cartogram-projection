using OWIDLayout, CSV, JSON, SHA
include(joinpath(@__DIR__,"..","src","review.jl"))
length(ARGS)==3 || error("Usage: review-corner-groups.jl OWID.csv SAVED_CELLS.csv OUTPUT_DIR")
owid,saved_cells,output = ARGS
ispath(output) && error("Use a new output directory")
codes = OWIDLayout.code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
inventory = read_target_groups(owid,codes)
original = Dict(p=>id for (id,points) in inventory.pieces for p in points)
saved = Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(saved_cells))
members = Dict(g=>[r.target_id for r in inventory.membership if r.group_id==g] for g in keys(inventory.groups))
merged = sort!([g for (g,ids) in members if length(ids)>1];by=g->(first(split(g,':')),parse(Int,last(split(g,':'))[2:end])))
scopes = sort!(unique(first(split(g,':')) for g in merged))
colours = ("#e9a86b","#8cbdd9","#b0cf81","#c6a1cf","#e6c764","#8ed0c2")
mkdir(output)
index = ["""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>OWID corner-connected groups</title><style>body{font:17px system-ui;max-width:1450px;margin:2rem auto;padding:0 1rem;background:#faf9f6;color:#222}img{width:100%;height:auto}nav a{display:inline-block;margin:.5rem}a{color:#08659d}article{border-top:1px solid #bbb;margin:2rem 0}p{max-width:85ch}</style>
<h1>OWID corner-connected groups</h1><p>The original artwork has <strong>$(length(inventory.pieces)) edge-connected pieces</strong> but
<strong>$(length(inventory.groups)) same-country edge-or-corner groups</strong>. $(length(merged)) groups join pieces in $(length(scopes)) country scopes.</p>
<p>Grouping never crosses country labels. A corner contact is not an international border.
The saved layout is unchanged. G labels identify artwork groups, not necessarily single geographic islands.
All original T labels are retained as children.</p>
<p><strong>How to read:</strong> Pieces in each merged group share a colour. Red circles mark original corner contacts between different T pieces.
Grey pieces do not merge with another piece. Both panels use the same scale.
The right panel shows where those same pieces are in the saved layout, even if resizing moved them apart.</p>
<p>Inspect Japan, the Philippines, New Zealand, and Hawaii in particular. A group can represent several real islands.
It must be able to receive several source components; it must not be forced to match one source island.</p>
<p><a href='../owid-scope-splits/index.html'>Saved layout</a> · <a href='membership.csv'>T-to-G table</a> · <a href='corner-contacts.csv'>Corner contacts</a> · <a href='summary.json'>Checks and input hashes</a></p><nav>
"""]
append!(index,["<a href='#$s'>$s</a>" for s in scopes]);push!(index,"</nav>")
function draw_comparison(path,scope,selected,fillmap)
    old = Dict(p=>id for (p,id) in original if startswith(id,"$scope:"))
    current = Dict(p=>id for (p,id) in saved if startswith(id,"$scope:"))
    points = [p for (p,id) in old if id in selected]
    append!(points,[p for (p,id) in current if id in selected])
    bounds = padded_bounds(points;minimum_span=6,padding=0.2)
    open(path,"w") do io
        svg_start(io,1400,600)
        println(io,"<text x='20' y='28' font-size='20'>Original OWID: corner contacts in red</text><text x='720' y='28' font-size='20'>Saved layout (unchanged)</text>")
        draw_tiles(io,old,"",bounds,20,55,660,510,"original";labels=true,colours=fillmap)
        draw_tiles(io,current,"",bounds,720,55,660,510,"saved";labels=true,colours=fillmap)
        transform,_ = panel_transform(bounds,20,55,660,510)
        for join in inventory.joins
            join.scope==scope && join.a in selected && join.b in selected || continue
            x,y = transform(((join.x+join.qx)/2,(join.y+join.qy)/2))
            println(io,"<circle cx='$x' cy='$y' r='4' fill='none' stroke='#c62828' stroke-width='1.5'><title>$(join.a) touches $(join.b) at a corner</title></circle>")
        end
        svg_end(io)
    end
end
for scope in scopes
    ids = [g for g in merged if startswith(g,"$scope:")]
    fillmap = Dict(id=>colours[mod1(i,length(colours))] for (i,g) in enumerate(ids) for id in members[g])
    allparts = [id for id in keys(inventory.pieces) if startswith(id,"$scope:")]
    filename = "$scope-overview.svg"
    draw_comparison(joinpath(output,filename),scope,Set(allparts),fillmap)
    push!(index,"<h2 id='$scope'>$scope</h2><a href='$filename'><img src='$filename' loading='lazy' alt='$scope corner groups'></a>")
    for g in ids
        labels=join(last.(split.(members[g],':')),", ")
        filename = "$scope-overview.svg"
        if Set(members[g]) != Set(allparts)
            filename=replace(g,':'=>'-')*".svg"
            draw_comparison(joinpath(output,filename),scope,Set(members[g]),fillmap)
        end
        push!(index,"<article><h3>$g: $labels</h3><p>$(length(inventory.groups[g])) original tiles. The group retains all child pieces.</p><a href='$filename'><img src='$filename' loading='lazy' alt='$g corner contacts'></a></article>")
    end
end
CSV.write(joinpath(output,"membership.csv"),inventory.membership)
CSV.write(joinpath(output,"corner-contacts.csv"),inventory.joins)
files=[owid,saved_cells,@__FILE__,joinpath(@__DIR__,"..","src","groups.jl"),joinpath(@__DIR__,"..","src","inputs.jl"),joinpath(@__DIR__,"..","src","review.jl")]
summary=(;edge_pieces=length(inventory.pieces),corner_groups=length(inventory.groups),merged_groups=length(merged),
    changed_scopes=scopes,land_tiles=sum(length,values(inventory.groups)),corner_contacts=length(inventory.joins),
    saved_layout_changed=false,input_sha256=Dict(p=>open(io->bytes2hex(sha256(io)),p) for p in files))
open(io->JSON.print(io,summary),joinpath(output,"summary.json"),"w")
push!(index,"<p>This is a grouping audit. Population assignment and layout resizing have not been rerun.</p></html>")
write(joinpath(output,"index.html"),join(index,"\n"))
println("$(length(inventory.pieces)) pieces -> $(length(inventory.groups)) groups; $(length(merged)) merged groups")
