using OWIDLayout, CSV, JSON, SHA
include(joinpath(@__DIR__,"..","src","review.jl"))
length(ARGS)==4 || error("Usage: review-group-resize.jl TRIAL_DIR COMPONENTS.csv POLYGONS.geojson OUTPUT_DIR")
trial,components,polygons,output=ARGS
ispath(output) && error("Use a new output directory")
report=JSON.parsefile(joinpath(trial,"report.json"))
report["complete"] || error("Cannot publish an incomplete layout")
load_cells(path)=Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(path))
before=load_cells(joinpath(trial,"before.csv")); after=load_cells(joinpath(trial,"cells.csv"))
budgets=collect(CSV.File(joinpath(trial,"budgets.csv")))
assignments=Dict(String(r.component_id)=>String(r.group_id) for r in CSV.File(joinpath(trial,"source-assignments.csv")))
source=Dict(String(r.component_id)=>r for r in CSV.File(components;types=String))
geometry=Dict(String(f["properties"]["component_id"])=>f["geometry"] for f in JSON.parsefile(polygons)["features"])
scopes=String.(report["changed_scopes"])
colours=("#e8a45c","#73afd0","#85be79","#b99acc","#d88191","#c5be63","#72beb0","#bba18d","#a3b5db","#c7a1aa",
         "#73a7a0","#b8c687","#d2b287","#a7a2c2","#e1b6b1","#8eaea5","#bbaa72","#7fa0bd","#c297b5","#c4bcaa")
mkdir(output)
page=["""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Corner groups: population resize</title><style>body{font:17px system-ui;max-width:1550px;margin:2rem auto;padding:0 1rem;background:#faf9f6;color:#222}img{width:100%;height:auto}a{color:#08659d}nav a{display:inline-block;margin:.5rem}table{border-collapse:collapse}td,th{padding:.35rem .7rem;text-align:left;border-bottom:1px solid #ddd}p{max-width:90ch}.note{padding:1rem;background:#fff0d5}</style>
<h1>Corner groups: population resize</h1>
<p>This is a separate Julia trial. The saved layout and H3-MON exports have not changed.
Population matching was rerun for the ten scopes affected by corner grouping. All other assignments remain from the saved layout.</p>
<p><strong>Checks:</strong> 54,967 land tiles; exact country totals; 18 groups change tile count;
all shared group borders retained; all 64 enclosed water cells retained at their original positions.
The layout has 244 groups, including the three added population scopes.</p>
<p>Each artwork group can receive several source components. Strong child matches add source anchors but do not receive separate tile budgets.
Unmatched source components join the nearest source anchor. Weak target groups share a nearby population pool.
The minimum is one tile per existing G group, not one tile per old T fragment.</p>
<div class="note">This remains an experimental match. There are no hand-written identity overrides in the rerun scopes.
Source-distance fallback is approximate. Source preparation and unchanged scopes still use the earlier pipeline.
Shared borders are held in place during local coast edits; this is not a new shared-island border fit.</div>
<p><strong>Read the images:</strong> The two tile panels share a scale. The geographic panel uses a separate scale.
Colours identify population pools in all three panels. Labels identify G groups. Fallback target groups can share a colour.
Only the selected country is shown. Empty space stays empty; no water tiles are assigned to countries.</p>
<p><a href='../owid-scope-splits/index.html'>Saved layout</a> · <a href='../julia-corner-groups/index.html'>Corner-group definitions</a> ·
<a href='budgets.csv'>Budgets</a> · <a href='source-assignments.csv'>Source assignments</a> · <a href='membership.csv'>Old T-to-G IDs</a> ·
<a href='cells.csv'>New cells</a> · <a href='report.json'>Checks and hashes</a></p><nav>
"""]
append!(page,["<a href='#$s'>$s</a>" for s in scopes]);push!(page,"</nav>")
for scope in scopes
    rows=sort([r for r in budgets if r.country==scope];by=r->parse(Int,last(split(r.group_id,':'))[2:end]))
    ids=String.(getproperty.(rows,:group_id))
    palette=Dict(g=>colours[mod1(i,length(colours))] for (i,g) in enumerate(ids))
    pools=Dict(String(r.group_id)=>String(r.population_group) for r in rows)
    fills=Dict(g=>palette[pools[g]] for g in ids)
    old=Dict(p=>g for (p,g) in before if g in ids); new=Dict(p=>g for (p,g) in after if g in ids)
    bounds=padded_bounds([collect(keys(old));collect(keys(new))];minimum_span=6,padding=.12)
    selected=sort!([id for (id,g) in assignments if startswith(g,"$scope:")])
    anchor=first(sort(selected;by=id->(-parse(Float64,source[id].population),id)))
    a=source[anchor];lon=(parse(Float64,a.west)+parse(Float64,a.east))/2;lat=(parse(Float64,a.south)+parse(Float64,a.north))/2
    shapes=Dict(id=>geo_rings(geometry[id],lon,lat) for id in selected)
    # Ignore sub-tile remote components only when choosing the view bounds. They
    # remain in assignments and are drawn if they fall within the viewport.
    significant=[id for id in selected if parse(Float64,source[id].population)>=sum(parse(Float64,source[j].population) for j in selected)/length(old)*.25]
    gb=padded_bounds([p for id in significant for rings in shapes[id] for p in first(rings)];minimum_span=.1,padding=.1)
    source_colours=Dict(id=>palette[assignments[id]] for id in selected)
    filename="$scope.svg"
    open(joinpath(output,filename),"w") do io
        svg_start(io,1800,690)
        println(io,"<text x='20' y='28' font-size='21'>$scope — saved layout</text><text x='620' y='28' font-size='21'>New group resize</text><text x='1220' y='28' font-size='21'>Source population pools</text>")
        draw_tiles(io,old,"",bounds,20,60,560,600,"before";labels=true,colours=fills)
        draw_tiles(io,new,"",bounds,620,60,560,600,"after";labels=true,colours=fills)
        draw_geography(io,shapes,"",gb,1220,60,560,600,"","source";colours=source_colours)
        transform,_=panel_transform(gb,1220,60,560,600)
        for g in sort!(unique(collect(values(pools))))
            candidates=[id for id in selected if assignments[id]==g]
            id=first(sort(candidates;by=id->(-parse(Float64,source[id].population),id)))
            centre,_=OWIDLayout.geometry_descriptor(geometry[id],lon,lat)
            x,y=transform((centre[1]*cosd(lat),centre[2]))
            1220<=x<=1780 && 60<=y<=660 || continue
            label=last(split(g,':'))
            println(io,"<text x='$x' y='$y' font-size='13' text-anchor='middle' paint-order='stroke' stroke='white' stroke-width='3'>$label</text>")
        end
        svg_end(io)
    end
    changed=count(r->r.before!=r.tiles,rows)
    push!(page,"<h2 id='$scope'>$scope — $changed groups change size</h2><a href='$filename'><img src='$filename' loading='lazy' alt='$scope saved and resized groups with source population assignments'></a>")
    push!(page,"<table><tr><th>Group</th><th>Saved tiles</th><th>New tiles</th><th>Population pool</th><th>Pool population</th><th>Match</th></tr>")
    for r in rows
        push!(page,"<tr><td>$(r.group_id)</td><td>$(r.before)</td><td>$(r.tiles)</td><td>$(r.population_group)</td><td>$(round(Int,r.pool_population))</td><td>$(r.identity)</td></tr>")
    end
    push!(page,"</table><p>Pool population is repeated for fallback groups. Do not add repeated pool values.</p>")
end
# Whole-world view, coloured by scope. Country borders remain visible.
world_scopes=sort!(unique(OWIDLayout.group_scope.(collect(values(after)))))
world_palette=Dict(s=>colours[mod1(i,length(colours))] for (i,s) in enumerate(world_scopes))
world_fills=Dict(g=>world_palette[OWIDLayout.group_scope(g)] for g in values(after))
world_bounds=padded_bounds(collect(keys(after));padding=.03)
open(joinpath(output,"world.svg"),"w") do io
    svg_start(io,1800,1150)
    println(io,"<text x='20' y='30' font-size='24'>World — corner-group population resize trial</text>")
    draw_tiles(io,after,"",world_bounds,20,60,1760,1060,"world";colours=world_fills)
    transform,_=panel_transform(world_bounds,20,60,1760,1060)
    parts=Dict{String,Vector{Tuple{Int,Int}}}()
    for (p,g) in after;push!(get!(parts,g,Tuple{Int,Int}[]),p);end
    for scope in world_scopes
        groups=[g for g in keys(parts) if OWIDLayout.group_scope(g)==scope]
        g=first(sort(groups;by=g->(-length(parts[g]),g)))
        points=parts[g]
        length(points)>=80 || continue
        x,y=transform(OWIDLayout.cell_centre(points))
        println(io,"<text x='$x' y='$y' font-size='13' text-anchor='middle' paint-order='stroke' stroke='white' stroke-width='3'>$scope</text>")
    end
    svg_end(io)
end
push!(page,"<h2>World</h2><a href='world.svg'><img src='world.svg' loading='lazy' alt='Whole-world trial layout'></a></html>")
write(joinpath(output,"index.html"),join(page,"\n"))
for filename in ("budgets.csv","source-assignments.csv","membership.csv","cells.csv","report.json")
    cp(joinpath(trial,filename),joinpath(output,filename))
end
open(joinpath(output,"review-inputs.json"),"w") do io
    paths=[components,polygons,@__FILE__,joinpath(@__DIR__,"..","src","review.jl")]
    JSON.print(io,Dict(p=>open(f->bytes2hex(sha256(f)),p) for p in paths))
end
println("Wrote review to $output")
