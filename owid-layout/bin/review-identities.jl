using OWIDLayout, CSV, JSON, SHA
include(joinpath(@__DIR__,"..","src","review.jl"))

length(ARGS)==7 || error("Usage: review-identities.jl OWID.csv SAVED_CELLS.csv SAVED_MATCHES.csv CANDIDATES.csv COMPONENTS.csv POLYGONS.geojson OUTPUT_DIR")
owid,saved_cells,saved_matches,candidates,components,polygons,output = ARGS
ispath(output) && error("Use a new output directory")
text(x) = ismissing(x) ? "" : String(x)
old = Dict("$(r.country):$(r.target_part)"=>r for r in CSV.File(saved_matches;types=String))
new = Dict(String(r.target_id)=>r for r in CSV.File(candidates;types=String))
changed = sort!([id for id in keys(new) if haskey(old,id) && text(new[id].source_id)!=text(old[id].anchor_component)];
                by=id->(first(split(id,':')),parse(Int,last(split(id,':'))[2:end])))
scopes = sort!(unique(first(split(id,':')) for id in changed))
rows = collect(CSV.File(owid;header=[:x,:y,:code],types=Int))
xs,ys = sort!(unique(r.x for r in rows)),sort!(unique(r.y for r in rows))
step = max(1,foldl(gcd,vcat(diff(xs),diff(ys));init=0))
raw = Dict(((r.x-first(xs))÷step,-(r.y-first(ys))÷step)=>r.code for r in rows)
codes = OWIDLayout.code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
original = Dict{Tuple{Int,Int},String}()
for scope in scopes
    for (i,part) in enumerate(OWIDLayout.connected_parts(p for (p,c) in raw if c==codes[scope]))
        for p in part
            original[p] = "$scope:T$i"
        end
    end
end
saved = Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(saved_cells))
source = Dict(String(r.component_id)=>r for r in CSV.File(components;types=String))
geometry = Dict(String(f["properties"]["component_id"])=>f["geometry"] for f in JSON.parsefile(polygons)["features"])
function source_scope(r)
    scope = text(haskey(codes,r.map_unit) ? r.map_unit : r.country_id)
    get(OWIDLayout.ALIASES,scope,scope)
end
mkdir(output)
index = ["""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Automatic island identities: review</title><style>
body{font:17px system-ui;max-width:1500px;margin:2rem auto;padding:0 1rem;background:#faf9f6;color:#222}img{width:100%;height:auto}a{color:#08659d}article{border-top:2px solid #ccc;margin-top:2rem}code{font-size:.85em}nav a{display:inline-block;margin:.4rem}td,th{text-align:left;padding:.4rem}p{max-width:80ch}.note{background:#fff0d5;padding:1rem}summary{cursor:pointer}
</style><h1>Automatic island identities: review</h1>
<p>The saved layout is unchanged. This page compares source identities, not proposed tile sizes.
There are $(length(changed)) changed candidates in $(length(scopes)) country scopes.</p>
<p><a href="../owid-scope-splits/index.html">Saved layout</a> · <a href="changes.csv">Change table</a> · <a href="provenance.json">Input hashes</a></p>
<div class="note"><strong>How to review:</strong> Start with each labelled country overview. For each changed piece,
compare the saved source and the Julia candidate. Ask whether the candidate is the correct physical island or exclave.
Do not choose by population rank alone. Report the piece ID and “saved”, “candidate”, or “neither”, with a place name if known.
An old fallback is a population group, not a confirmed island identity.
Population figures below refer to source components, not whole fallback groups.</div>
<p>Both tile panels use the same scale within a card. Both main geography panels also use the same scale within a card.
Tile coordinates and geographic coordinates have different scales. Each geography detail inset has its own scale.
North is up. Orange marks the selected saved source; blue marks the candidate. Grey shows other pieces in the same population scope.
Other countries are omitted. A dashed circle locates a component too small to see at the main map scale.</p><nav>
"""]
append!(index,["<a href='#$s'>$s</a>" for s in scopes]); push!(index,"</nav>")
changes = NamedTuple[]
for scope in scopes
    ids = filter(id->startswith(id,"$scope:"),changed)
    original_scope = Dict(p=>id for (p,id) in original if startswith(id,"$scope:"))
    saved_scope = Dict(p=>id for (p,id) in saved if startswith(id,"$scope:"))
    scope_points = [collect(keys(original_scope));collect(keys(saved_scope))]
    bounds = padded_bounds(scope_points;minimum_span=4)
    overview = "$scope-overview.svg"
    open(joinpath(output,overview),"w") do io
        svg_start(io,1400,540)
        println(io,"<text x='20' y='28' font-size='21'>$scope: original OWID</text><text x='720' y='28' font-size='21'>Saved layout (unchanged)</text>")
        draw_tiles(io,original_scope,"",bounds,20,55,660,460,"original";labels=true,highlights=Set(ids))
        draw_tiles(io,saved_scope,"",bounds,720,55,660,460,"saved";labels=true,highlights=Set(ids))
        svg_end(io)
    end
    push!(index,"<h2 id='$scope'>$scope — $(length(ids)) changed candidates</h2><p>Orange pieces have changed candidates. T labels identify the same target piece in both panels.</p><a href='$overview'><img loading='lazy' src='$overview' alt='$scope original and saved tile pieces'></a>")
    scope_sources = sort!([id for (id,r) in source if source_scope(r)==scope])
    anchor = first(sort(scope_sources;by=id->(-parse(Float64,source[id].population),id)))
    a = source[anchor]; longitude=(parse(Float64,a.west)+parse(Float64,a.east))/2; latitude=(parse(Float64,a.south)+parse(Float64,a.north))/2
    shapes = Dict(id=>geo_rings(geometry[id],longitude,latitude) for id in scope_sources)
    for id in ids
        before = text(old[id].anchor_component); after = text(new[id].source_id)
        fallback = text(old[id].identity)=="nearest_target_group"
        tag = fallback ? "Saved fallback group — not a confirmed identity" : "Saved identity: $(text(old[id].identity))"
        tile_points = [p for (p,label) in original_scope if label==id]
        append!(tile_points,[p for (p,label) in saved_scope if label==id])
        tb = padded_bounds(tile_points;minimum_span=8,padding=0.6)
        selected = filter(!isempty,[before,after])
        points = [p for s in selected for rings in shapes[s] for p in first(rings)]
        gb = padded_bounds(points;minimum_span=0.1,padding=0.25)
        file = replace(id,':'=>'-')*".svg"
        open(joinpath(output,file),"w") do io
            svg_start(io,1600,600)
            for (i,title) in enumerate(("Original OWID piece","Saved layout (unchanged)","Saved source","Julia candidate"))
                println(io,"<text x='$((i-1)*400+15)' y='28' font-size='19'>$(escape_markup(title))</text>")
            end
            draw_tiles(io,original_scope,id,tb,15,65,370,340,"old-tiles";labels=true)
            draw_tiles(io,saved_scope,id,tb,415,65,370,340,"saved-tiles";labels=true)
            for (i,selected_id,colour) in ((3,before,"#eaa35e"),(4,after,"#52a8d3"))
                x=(i-1)*400+15
                if isempty(selected_id)
                    println(io,"<text x='$x' y='100' font-size='18'>No candidate</text>")
                    continue
                end
                draw_geography(io,shapes,selected_id,gb,x,65,370,340,colour,"geo-$i")
                detail = padded_bounds([p for rings in shapes[selected_id] for p in first(rings)])
                println(io,"<rect x='$(x+235)' y='430' width='135' height='125' fill='white' stroke='#777'/><text x='$(x+240)' y='445' font-size='10'>Detail: own scale</text>")
                draw_geography(io,Dict(selected_id=>shapes[selected_id]),selected_id,detail,x+240,453,125,95,colour,"detail-$i")
                r=source[selected_id]
                println(io,"<text x='$x' y='575' font-size='13'>Component population: $(round(Int,parse(Float64,r.population)))</text>")
            end
            println(io,"<text x='15' y='435' font-size='14'>$(escape_markup(id)) — orange marks this target piece</text>")
            svg_end(io)
        end
        oldname = text(source[before].name)
        newname = isempty(after) ? "No candidate" : text(source[after].name)
        push!(changes,(;target_id=id,saved_source=before,candidate_source=after,saved_kind=text(old[id].identity),saved_name=oldname,candidate_name=newname))
        function description(s)
            isempty(s) && return "No candidate"
            r=source[s]
            lon=(parse(Float64,r.west)+parse(Float64,r.east))/2; lat=(parse(Float64,r.south)+parse(Float64,r.north))/2
            map = "https://www.openstreetmap.org/?mlat=$lat&amp;mlon=$lon#map=8/$lat/$lon"
            "$(escape_markup(r.name)) · <a href='$map'>$(round(lon;digits=3))°, $(round(lat;digits=3))° on map</a> · <code>$(escape_markup(s))</code>"
        end
        push!(index,"<article id='$(replace(id,':'=>'-'))'><h3>$(escape_markup(id))</h3><p>$tag</p><p><strong>Saved:</strong> $(description(before))<br><strong>Candidate:</strong> $(description(after))</p><a href='$file'><img loading='lazy' src='$file' alt='$(escape_markup(id)) identity comparison'></a></article>")
    end
end
CSV.write(joinpath(output,"changes.csv"),changes)
paths=[ARGS[1:6];@__FILE__;joinpath(@__DIR__,"..","src","review.jl")]
open(joinpath(output,"provenance.json"),"w") do io
    JSON.print(io,Dict(p=>open(f->bytes2hex(sha256(f)),p) for p in paths))
end
push!(index,"<hr><p>This is a review of automatic candidates. No candidate on this page has changed the saved layout.</p></html>")
write(joinpath(output,"index.html"),join(index,"\n"))
println("Wrote $(length(changed)) comparisons in $(length(scopes)) scopes to $output")
