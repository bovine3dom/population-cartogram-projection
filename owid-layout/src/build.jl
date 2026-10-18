"""Build a layout from three datasets. Do not reuse saved identity assignments."""
function build_layout(kontur,boundary,cartogram,output;
                      country_codes=joinpath(@__DIR__,"../config/country-codes.csv"),
                      scope_crosswalk=joinpath(@__DIR__,"../config/scope-crosswalk.csv"),
                      node_limit=100_000)
    ispath(output) && error("Use a new build directory")
    country_codes=abspath(country_codes)
    scope_crosswalk=isnothing(scope_crosswalk) ? nothing : abspath(scope_crosswalk)
    root=normpath(joinpath(@__DIR__,".."))
    files=[joinpath(@__DIR__,f) for f in readdir(@__DIR__) if endswith(f,".jl")]
    append!(files,[country_codes,joinpath(root,"Project.toml"),joinpath(root,"Manifest.toml")])
    isnothing(scope_crosswalk) || push!(files,scope_crosswalk)
    record=Dict{String,Any}("complete"=>false,"stage"=>"sources",
        "inputs"=>Dict(abspath(p)=>file_digest(p) for p in (kontur,boundary,cartogram)),
        "code_and_policy"=>Dict(p=>file_digest(p) for p in files),
        "options"=>Dict("country_codes"=>country_codes,"scope_crosswalk"=>scope_crosswalk,"node_limit"=>node_limit))
    mkpath(output);path=joinpath(output,"build.json")
    write_json_atomic(path,record)
    try
        record["sources"]=prepare_sources(kontur,boundary,joinpath(output,"sources"))
        record["stage"]="layout";write_json_atomic(path,record);GC.gc()
        layout=clean_layout(joinpath(output,"sources"),cartogram,joinpath(output,"layout");country_codes,scope_crosswalk,node_limit)
        record["layout"]=layout
        layout["complete"] || error("Layout fit failed; inspect layout/report.json")
        record["complete"]=true;record["stage"]="complete";write_json_atomic(path,record)
    catch exception
        record["stage"]="failed";record["error"]=sprint(showerror,exception)
        write_json_atomic(path,record);rethrow()
    end
    record
end
