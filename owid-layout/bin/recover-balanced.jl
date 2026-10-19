using OWIDLayout
using OWIDLayout: JSON, Arrow, DataFrame

"""Recover checked balanced shards across the reviewed CPU balance fix only.

Normal resume still requires identical code. This separate operation creates
an audited new run. It never changes the old job or accepts changed input data.
"""
function recover_balanced(build, previous, output;backend=OWIDLayout.KA.CPU())
    ispath(output) && error("Use a new recovery directory")
    oldpath=joinpath(previous,"mapping-job.json");old=JSON.parsefile(oldpath)
    before=old["signature"]
    after=OWIDLayout.mapping_signature(build,before["resolution"],backend)
    Dict(k=>v for (k,v) in before if k!="files")==Dict(k=>v for (k,v) in after if k!="files") || error("Backend or resolution changed")
    Set(keys(before["files"]))==Set(keys(after["files"])) || error("Input file set changed")
    changed=sort!([p for (p,hash) in before["files"] if after["files"][p]!=hash])
    allowed=Set(abspath(joinpath(@__DIR__,"../src",f)) for f in ("mapping_fit.jl","mapping_export.jl"))
    !isempty(changed) && issubset(Set(changed),allowed) || error("Recovery permits only the reviewed balance and checkpoint code changes")
    inputs=OWIDLayout.mapping_inputs(build;resolution=before["resolution"])
    sources,targets=inputs.sources,inputs.targets
    groups=sort!(unique(sources.group_id))
    issubset(Set(keys(old["shards"])),Set(groups)) || error("Unknown completed group")
    isempty(old["shards"]) && error("No balanced shards to recover")
    parent=dirname(abspath(output));mkpath(parent);temp=mktempdir(parent;prefix="recover-")
    job=Dict{String,Any}("signature"=>after,"complete"=>false,"phase"=>"recovered",
        "shards"=>Dict{String,Any}(),"raw_shards"=>Dict{String,Any}(),
        "recovery"=>Dict("previous_job"=>abspath(oldpath),"previous_job_sha256"=>OWIDLayout.file_digest(oldpath),
            "changed_code"=>Dict(p=>Dict("before"=>before["files"][p],"after"=>after["files"][p]) for p in changed)))
    try
        mkdir(joinpath(temp,"shards"))
        for (i,group) in enumerate(groups)
            haskey(old["shards"],group) || continue
            original=joinpath(previous,"shards","$i.arrow")
            hash=OWIDLayout.file_digest(original)
            hash==old["shards"][group]["sha256"] || error("Changed balanced shard")
            s=sources[sources.group_id.==group,:];t=targets[targets.group_id.==group,:]
            checks=OWIDLayout.check_mapping(DataFrame(Arrow.Table(original)),s,t;tolerance=1e-6)
            cp(original,joinpath(temp,"shards","$i.arrow"))
            job["shards"][group]=Dict("sha256"=>hash,"checks"=>checks)
            println("Recovered ",group,": ",checks["tiles"]," tiles");flush(stdout)
        end
        OWIDLayout.write_json_atomic(joinpath(temp,"mapping-job.json"),job)
        mv(temp,output)
    finally
        ispath(temp) && rm(temp;recursive=true)
    end
    job
end
