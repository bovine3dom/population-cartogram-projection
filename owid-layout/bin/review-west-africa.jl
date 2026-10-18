using OWIDLayout, CSV, JSON
include(joinpath(@__DIR__,"../src/review.jl"))
length(ARGS)>=3 || error("Usage: review-west-africa.jl CLEAN_BUILD OUTPUT_DIR TRIAL_DIR...")
root,output=ARGS[1:2];trials=ARGS[3:end]
ispath(output) && error("Use a new review directory")
mkpath(output)
load_cells(path)=Dict((r.x,r.y)=>OWIDLayout.group_scope(String(r.component_id)) for r in CSV.File(path))
before=load_cells(joinpath(root,"layout/cells.csv"))
reports=JSON.parsefile.(joinpath.(trials,"report.json"))
region=String.(first(reports)["region"])
colours=("#c09bcc","#e8a45c","#73afd0","#85be79","#d88191","#c5be63","#72beb0","#bba18d","#a3b5db","#c7a1aa","#73a7a0","#b8c687","#d2b287","#a7a2c2","#e1b6b1")
palette=Dict(s=>colours[i] for (i,s) in enumerate(region))
bounds=padded_bounds([p for (p,s) in before if s in region];padding=.12)
function panel(io,cells,audit,x,clip)
    draw_tiles(io,cells,"BFA",bounds,x,60,850,780,clip;labels=true,colours=palette)
    wrong=Set(Tuple(String.(p)) for p in audit["false_contacts"])
    transform,_=panel_transform(bounds,x,60,850,780)
    println(io,"<g clip-path='url(#$clip)'>")
    for (p,s) in sort!(collect(cells);by=first),(dx,dy) in ((1,0),(0,1))
        q=(p[1]+dx,p[2]+dy);t=get(cells,q,s)
        minmax(s,t) in wrong || continue
        a=dx==1 ? (p[1]+.5,p[2]-.5) : (p[1]-.5,p[2]+.5)
        b=dx==1 ? (p[1]+.5,p[2]+.5) : (p[1]+.5,p[2]+.5)
        ax,ay=transform(a);bx,by=transform(b)
        println(io,"<path d='M$ax,$ay L$bx,$by' stroke='#c71920' stroke-width='2.2'/>")
    end
    println(io,"</g>")
end
page=["""<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width'>
<title>West Africa border trial</title><style>body{font:17px system-ui;max-width:1800px;margin:2rem auto;padding:1rem;background:#faf9f6}img{width:100%}table{border-collapse:collapse}td,th{padding:.5rem;border-bottom:1px solid #ccc;text-align:left}p{max-width:100ch}.note{background:#fff0d5;padding:1rem}</style>
<h1>West Africa: geographic border trial</h1>
<p>This is a separate experiment. The approved clean layout and H3-MON exports have not changed.
Country tile counts and the regional outline are fixed. Colours identify countries; grey countries are outside the trial.
Red lines mark shared tile edges between countries that do not share a border in Natural Earth.
Missing neighbours appear in the tables, not as red lines. BFA is Burkina Faso; BEN is Benin;
TGO is Togo; NER is Niger; NGA is Nigeria.</p>
<p class='note'>The African mainland currently has no enclosed empty cells: this trial does not add lakes.
Exact trials require all Natural Earth neighbour pairs inside the region, with no extra pairs.
Local exchanges and penalized fits can retain wrong contacts. Geographic seeds do not enforce neighbours.
The table reports all remaining errors; none of these trials is an approved map.
Outside countries stay fixed. Their border errors are shown, not accepted as correct geography.
Same-country corner contact counts as connected; country borders require shared edges.</p>
<p><a href='geography.svg'>Natural Earth reference</a> · <a href='../owid-clean-build/world.svg'>Current world map</a></p>
"""]
open(joinpath(output,"before.svg"),"w") do io
    svg_start(io,900,880)
    println(io,"<text x='25' y='30' font-size='23'>Current West Africa — red borders lack geographic support</text>")
    panel(io,before,first(reports)["before"],25,"before")
    svg_end(io)
end
push!(page,"<p><a href='before.svg'>Current regional map with border errors</a></p>")
for (trial,report) in zip(trials,reports)
    mode=String(report["mode"]);cp(joinpath(trial,"report.json"),joinpath(output,"$mode-report.json"))
    push!(page,"<h2>$mode</h2><p><a href='$mode-report.json'>Checks, input hashes, and solver report</a></p>")
    if !report["complete"]
        push!(page,"<p>No validated fit was produced. See the solver report for the stopping reason. This is not proof that no fit exists.</p>")
        continue
    end
    after=load_cells(joinpath(trial,"cells.csv"));filename="$mode.svg"
    open(joinpath(output,filename),"w") do io
        svg_start(io,1800,880)
        println(io,"<text x='25' y='30' font-size='23'>Current clean layout</text><text x='925' y='30' font-size='23'>$mode — fixed regional outline</text>")
        panel(io,before,report["before"],25,"before")
        panel(io,after,report["after"],925,"after")
        svg_end(io)
    end
    cp(joinpath(trial,"cells.csv"),joinpath(output,"$mode-cells.csv"))
    push!(page,"<a href='$filename'><img src='$filename' alt='Current and refined West Africa'></a>")
    push!(page,"<table><tr><th>Check</th><th>Before</th><th>After</th></tr>")
    for (key,title) in (("false_internal_contacts","Extra internal neighbours"),("missing_internal_contacts","Missing internal neighbours"),("false_contacts","Extra neighbours, including outside"),("missing_contacts","Missing neighbours, including outside"))
        a,b=report["before"][key],report["after"][key]
        push!(page,"<tr><td>$title</td><td>$(length(a))</td><td>$(length(b))</td></tr>")
    end
    for (title,a,b) in (("Total country perimeter",report["before"]["total_perimeter"],report["after"]["total_perimeter"]),("Burkina Faso perimeter",report["before"]["perimeters"]["BFA"],report["after"]["perimeters"]["BFA"]))
        push!(page,"<tr><td>$title</td><td>$a</td><td>$b</td></tr>")
    end
    push!(page,"</table><p>$(report["changed_cells"]) of $(report["tiles"]) regional cells change country. Country budgets remain exact. All countries remain connected under the corner-contact rule.</p>")
    for key in ("false_contacts","missing_contacts")
        pairs=join([join(p,"–") for p in report["after"][key]],", ")
        push!(page,"<p><strong>Remaining $key:</strong> $pairs</p>")
    end
end
# Separate-scale geographic context. Do not present undistorted areas as tile quotas.
codes=OWIDLayout.code_table(joinpath(@__DIR__,"../config/country-codes.csv"))
sources=OWIDLayout.read_sources(joinpath(root,"layout/components.csv"),joinpath(root,"sources/polygons.geojson"),codes)
scopes=Dict(p.id=>s for (s,ps) in sources for p in ps)
features=JSON.parsefile(joinpath(root,"sources/polygons.geojson"))["features"]
shapes=Dict(String(f["properties"]["component_id"])=>geo_rings(f["geometry"],0.,12.) for f in features if haskey(scopes,String(f["properties"]["component_id"])))
geo_bounds=padded_bounds([p for (id,polys) in shapes if scopes[id] in region for rings in polys for p in first(rings)];padding=.07)
geo_colours=Dict(id=>get(palette,scopes[id],"#dedbd3") for id in keys(shapes))
open(joinpath(output,"geography.svg"),"w") do io
    svg_start(io,1200,950)
    println(io,"<text x='20' y='30' font-size='23'>Natural Earth — separate geographic scale</text>")
    draw_geography(io,shapes,"",geo_bounds,20,60,1160,860,"","geography";colours=geo_colours)
    transform,_=panel_transform(geo_bounds,20,60,1160,860)
    geometries=Dict(String(f["properties"]["component_id"])=>f["geometry"] for f in features)
    for s in region
        id=first(sort(sources[s];by=p->(-p.mass,p.id))).id
        centre,_=OWIDLayout.geometry_descriptor(geometries[id],0.,12.)
        x,y=transform((centre[1]*cosd(12.),centre[2]))
        println(io,"<text x='$x' y='$y' text-anchor='middle' font-size='15' paint-order='stroke' stroke='white' stroke-width='3'>$s</text>")
    end
    svg_end(io)
end
push!(page,"<h2>Geographic reference</h2><a href='geography.svg'><img src='geography.svg' alt='Natural Earth West Africa'></a></html>")
write(joinpath(output,"index.html"),join(page,"\n"))
println("Wrote $output")
