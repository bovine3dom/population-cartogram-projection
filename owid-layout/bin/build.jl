using OWIDLayout, JSON
length(ARGS)==4 || error("Usage: build.jl KONTUR.arrow NATURAL_EARTH.geojson OWID.csv OUTPUT_DIR")
kontur,boundary,owid,output=ARGS
ispath(output) && error("Use a new build directory")
mkpath(output)
record=Dict{String,Any}("complete"=>false,"stage"=>"sources","inputs"=>Dict(p=>OWIDLayout.file_digest(p) for p in (kontur,boundary,owid)))
root=normpath(joinpath(@__DIR__,".."))
files=[joinpath(root,"src",f) for f in readdir(joinpath(root,"src")) if endswith(f,".jl")]
append!(files,[joinpath(root,"config",f) for f in readdir(joinpath(root,"config"))])
append!(files,[joinpath(root,"Project.toml"),joinpath(root,"Manifest.toml"),@__FILE__])
record["code_and_policy"]=Dict(p=>OWIDLayout.file_digest(p) for p in files)
save()=open(io->JSON.print(io,record),joinpath(output,"build.json"),"w")
save()
try
    record["sources"]=OWIDLayout.prepare_sources(kontur,boundary,joinpath(output,"sources"))
    record["stage"]="layout";save();GC.gc()
    layout=OWIDLayout.clean_layout(joinpath(output,"sources"),owid,joinpath(output,"layout"))
    record["complete"]=layout["complete"];record["stage"]=layout["complete"] ? "complete" : "blocked"
    record["layout"]=layout;save()
    record["complete"] || exit(2)
catch exception
    record["stage"]="failed";record["error"]=sprint(showerror,exception);save();rethrow()
end
println("Clean build complete: ",output)
