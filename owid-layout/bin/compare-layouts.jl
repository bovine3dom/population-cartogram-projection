using OWIDLayout, CSV, JSON
include(joinpath(@__DIR__,"..","src","review.jl"))
length(ARGS)==3 || error("Usage: compare-layouts.jl SAVED_CELLS.csv NEW_CELLS.csv OUTPUT_DIR")
saved,new,output=ARGS
ispath(output) && error("Use a new review directory")
load(path)=Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(path))
a,b=load(saved),load(new)
mkdir(output)
scopes=sort!(unique(OWIDLayout.group_scope.(collect(values(a)))))
colours=("#e8a45c","#73afd0","#85be79","#b99acc","#d88191","#c5be63","#72beb0","#bba18d","#a3b5db","#c7a1aa",
         "#73a7a0","#b8c687","#d2b287","#a7a2c2","#e1b6b1","#8eaea5","#bbaa72","#7fa0bd","#c297b5","#c4bcaa")
page=["<!doctype html><meta charset='utf-8'><title>Saved and clean layouts</title><style>body{font:17px system-ui;max-width:1600px;margin:2rem auto}img{width:100%}</style><h1>Saved and clean layouts</h1><p>Left: saved corner-group trial. Right: new build from raw inputs. Each pair uses the same scale. Colours identify country scopes, not islands. The saved layout is a comparison input only.</p>"]
for (name,selected) in (("World",scopes),("Borneo and Indonesia",["MYS","BRN","SGP","IDN","TLS","PNG"]),("Philippines",["PHL"]),("Japan",["JPN"]),("New Zealand",["NZL"]),("British Isles",["GBR","IRL"]),("United States",["USA","CAN","MEX"]))
    left=Dict(p=>g for (p,g) in a if OWIDLayout.group_scope(g) in selected)
    right=Dict(p=>g for (p,g) in b if OWIDLayout.group_scope(g) in selected)
    palette=Dict(s=>colours[mod1(i,length(colours))] for (i,s) in enumerate(selected))
    fills=Dict(g=>palette[OWIDLayout.group_scope(g)] for g in union(values(left),values(right)))
    bounds=padded_bounds([collect(keys(left));collect(keys(right))];minimum_span=6,padding=.06)
    filename=replace(lowercase(name),' '=>'-')*".svg"
    open(joinpath(output,filename),"w") do io
        svg_start(io,1800,800)
        println(io,"<text x='20' y='30' font-size='24'>Saved — $name</text><text x='920' y='30' font-size='24'>Clean build — $name</text>")
        draw_tiles(io,left,"",bounds,20,60,860,720,"saved";colours=fills)
        draw_tiles(io,right,"",bounds,920,60,860,720,"clean";colours=fills)
        svg_end(io)
    end
    push!(page,"<h2>$name</h2><a href='$filename'><img src='$filename' alt='$name: saved and clean layouts'></a>")
end
write(joinpath(output,"index.html"),join(page,"\n"))
open(io->JSON.print(io,Dict(p=>OWIDLayout.file_digest(p) for p in (saved,new,@__FILE__))),joinpath(output,"inputs.json"),"w")
