using OWIDLayout, CSV, DataFrames, JSON
length(ARGS)>=3 || error("Usage: regional-mapping.jl BUILD_DIR EXPORT_DIR COUNTRY...")
build,output=ARGS[1:2];countries=Set(ARGS[3:end])
ispath(output) && error("Use a new export directory")
inputs=mapping_inputs(build;resolution=5)
targets=inputs.targets[in.(inputs.targets.country,Ref(countries)),:]
Set(targets.country)==countries || error("Unknown country scope")
sources=inputs.sources[in.(inputs.sources.group_id,Ref(Set(targets.group_id))),:]
mappings=DataFrame[];checks=Dict{String,Any}()
for group in sort!(unique(targets.group_id))
    println("Fit ",group);flush(stdout)
    mapping,check=fit_pool(sources[sources.group_id.==group,:],targets[targets.group_id.==group,:])
    push!(mappings,mapping);checks[group]=check
end
export_mapping(vcat(mappings...),sources,targets,output)
record=Dict("countries"=>sort!(collect(countries)),"world_input_audit"=>inputs.audit,"fits"=>checks,
    "layout_sha256"=>OWIDLayout.file_digest(joinpath(build,"layout/cells.csv")),
    "test_sha256"=>OWIDLayout.file_digest(@__FILE__))
open(io->JSON.print(io,record),joinpath(output,"regional-review.json"),"w")
println("Regional export complete: ",output)
