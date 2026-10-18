using OWIDLayout, CSV, JSON
include(joinpath(@__DIR__,"../src/review.jl"))
length(ARGS)==2 || error("Usage: review-block-slide.jl TRIAL_DIR OUTPUT_DIR")
trial,output=ARGS
ispath(output) && error("Use a new review directory")
report=JSON.parsefile(joinpath(trial,"report.json"));report["complete"] || error("Incomplete trial")
load_cells(path)=Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(path))
before=load_cells(joinpath(trial,"before.csv"))
scoped(cells)=Dict(p=>String(OWIDLayout.group_scope(g)) for (p,g) in cells)
old=scoped(before)
region=Set(["BFA","NGA","GHA","CIV","TGO","BEN","MLI","SEN","MRT","NER"])
context=padded_bounds([p for (p,g) in old if g in region];padding=.06)
palette=Dict("BFA"=>"#eca34d","NGA"=>"#a7c887","GHA"=>"#87b8cf","CIV"=>"#c5b3d1",
             "TGO"=>"#dcb5c6","BEN"=>"#d7988e","MLI"=>"#9caecf","SEN"=>"#cbbd8c","MRT"=>"#c9afb2","NER"=>"#a6c4bd")
mkpath(output)
counts=report["variants"]["south-slide"]
page=["""<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width'>
<title>West Africa: move the pieces</title><style>body{font:17px system-ui;max-width:1800px;margin:2rem auto;padding:1rem;background:#faf9f6}img{width:100%}p{max-width:100ch}table{border-collapse:collapse}td,th{padding:.5rem;border-bottom:1px solid #ccc;text-align:left}.note{padding:1rem;background:#fff0d5}</style>
<h1>Move Burkina Faso south; lift a Nigerian block north</h1>
<p>This trial moves existing pieces. It does not repartition West Africa. Burkina Faso keeps its exact outline, orientation, and $(counts["moving_tiles"]) tiles.
Nigeria keeps $(counts["receiver_tiles"]) tiles. Every other country stays in exactly the same place. The combined land mask stays unchanged:
there are no new gaps, holes, or water tiles.</p>
<p class='note'>The current map and H3-MON exports have not changed. These are two-country movement trials, not complete geographic fixes.
The selected Nigerian block comes from the western arm; the rest of Nigeria stays fixed. This does not move the entire arm as a predefined piece.
A purely southward move is blocked with all other countries fixed, so both candidates also move Burkina Faso a short distance east.</p>
<p><a href='#south-slide'>Small join adjustment</a> · <a href='#rigid-swap'>Two rigid pieces</a> · <a href='world.svg'>Trial world map</a> ·
<a href='report.json'>Checks and input hashes</a> · <a href='candidates.csv'>Searched placements</a></p>
"""]
for name in ("south-slide","rigid-swap")
    checks=report["variants"][name];selection=checks["selection"]
    after=scoped(load_cells(joinpath(trial,name,"cells.csv")))
    motions=collect(CSV.File(joinpath(trial,name,"motions.csv")))
    block=[r for r in motions if r.piece=="receiving"]
    rigid_steps=-Int(selection["counter_dy"])÷Int(selection["dy"])
    seams=[r for r in block if r.steps!=rigid_steps]
    title=name=="south-slide" ? "South slide — small join adjustment" : "Exact rigid-piece swap"
    filename="$name.svg"
    open(joinpath(output,filename),"w") do io
        svg_start(io,1800,1000)
        println(io,"<text x='25' y='30' font-size='23'>Current map</text><text x='925' y='30' font-size='23'>$title</text>")
        draw_tiles(io,old,"BFA",context,25,65,850,900,"before";labels=true,colours=palette)
        draw_tiles(io,after,"BFA",context,925,65,850,900,"after";labels=true,colours=palette)
        svg_end(io)
    end
    detail=padded_bounds([(r.from_x,r.from_y) for r in motions] ∪ [(r.to_x,r.to_y) for r in motions];padding=.12)
    source=copy(old);dest=copy(after)
    for r in block;source[(r.from_x,r.from_y)]="NGA:block";dest[(r.to_x,r.to_y)]="NGA:block";end
    fills=merge(palette,Dict("NGA:block"=>"#43845b"))
    open(joinpath(output,"$name-movement.svg"),"w") do io
        svg_start(io,1800,750)
        println(io,"<text x='25' y='30' font-size='23'>Before — dark green is the Nigerian block</text><text x='925' y='30' font-size='23'>After — orange outline is unchanged</text>")
        for (cells,x,clip) in ((source,25,"source"),(dest,925,"dest"))
            draw_tiles(io,cells,"BFA",detail,x,60,850,650,clip;labels=true,colours=fills)
            transform,scale=panel_transform(detail,x,60,850,650)
            for r in seams
                p=clip=="source" ? (r.from_x,r.from_y) : (r.to_x,r.to_y)
                px,py=transform((p[1]-.5,p[2]+.5))
                println(io,"<rect x='$px' y='$py' width='$scale' height='$scale' fill='none' stroke='#9a237e' stroke-width='2.5'/>")
            end
        end
        println(io,"<text x='25' y='735' font-size='16'>Dark green is a movement overlay, not a new country. Purple boxes mark join adjustments.</text>")
        svg_end(io)
    end
    push!(page,"<h2 id='$name'>$title</h2><p>Burkina Faso moves $(selection["dx"]) tiles east and $(-selection["dy"]) tiles south.")
    push!(page,"$(selection["counter_rigid_tiles"]) of $(selection["counter_tiles"]) Nigerian block tiles move together $(-selection["counter_dx"]) tiles west and $(selection["counter_dy"]) tiles north.")
    push!(page,"$(selection["seam_tiles"]) Nigerian tiles need a join adjustment. The other $(checks["receiver_stationary_tiles"]) Nigerian tiles do not move.</p>")
    push!(page,"<a href='$filename'><img src='$filename' alt='$title: before and after'></a><details open><summary>Which pieces moved?</summary><a href='$name-movement.svg'><img src='$name-movement.svg' alt='Rigid movement and join adjustments'></a></details>")
    push!(page,"<p>Burkina Faso's neighbours after this move: $(join(checks["neighbours_after"]["BFA:G1"],", ")). No neighbour graph was enforced.</p>")
    cp(joinpath(trial,name,"cells.csv"),joinpath(output,"$name-cells.csv"))
    cp(joinpath(trial,name,"motions.csv"),joinpath(output,"$name-motions.csv"))
    push!(page,"<p><a href='$name-cells.csv'>World cells</a> · <a href='$name-motions.csv'>Tile movements</a></p>")
end
# Show the south-slide candidate in the full world context.
world=scoped(load_cells(joinpath(trial,"south-slide/cells.csv")))
colours=("#e8a45c","#73afd0","#85be79","#b99acc","#d88191","#c5be63","#72beb0","#bba18d","#a3b5db","#c7a1aa",
         "#73a7a0","#b8c687","#d2b287","#a7a2c2","#e1b6b1","#8eaea5","#bbaa72","#7fa0bd","#c297b5","#c4bcaa")
world_colours=Dict(g=>colours[mod1(i,length(colours))] for (i,g) in enumerate(sort!(unique(collect(values(world))))))
world_colours["BFA"]=palette["BFA"];world_colours["NGA"]=palette["NGA"]
world_bounds=padded_bounds(collect(keys(world));padding=.03)
open(joinpath(output,"world.svg"),"w") do io
    svg_start(io,1800,1150)
    println(io,"<text x='20' y='30' font-size='24'>World — two-piece south-slide trial</text>")
    draw_tiles(io,world,"",world_bounds,20,60,1760,1060,"world";colours=world_colours)
    svg_end(io)
end
push!(page,"<h2>World context</h2><a href='world.svg'><img src='world.svg' alt='World with the two-piece movement trial'></a></html>")
write(joinpath(output,"index.html"),join(page,"\n"))
for f in ("report.json","candidates.csv");cp(joinpath(trial,f),joinpath(output,f));end
open(io->JSON.print(io,Dict(p=>OWIDLayout.file_digest(p) for p in (@__FILE__,joinpath(@__DIR__,"../src/review.jl")))),joinpath(output,"renderer.json"),"w")
println("Wrote ",output)
