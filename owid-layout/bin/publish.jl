using OWIDLayout, JSON

function publish_mapping(mapping, destination)
    ispath(destination) && error("Use a new H3-MON dataset directory")
    jobpath=joinpath(mapping,"mapping-job.json")
    JSON.parsefile(jobpath)["complete"] || error("Mapping is not complete")
    source=joinpath(mapping,"h3-mon")
    checks=JSON.parsefile(joinpath(source,"checks.json"))
    checks["cross_pool_population"]==0 && checks["maximum_relative_target_error"]<=OWIDLayout.BALANCE_TOLERANCE || error("Mapping checks failed")
    all(OWIDLayout.file_digest(joinpath(source,f))==hash for (f,hash) in checks["files"]) || error("Export files changed")
    parent=dirname(abspath(destination));mkpath(parent)
    temp=mktempdir(parent;prefix="publish-")
    try
        for f in keys(checks["files"])
            basename(f)==f || error("Invalid export filename")
            cp(joinpath(source,f),joinpath(temp,f))
        end
        metadata_path=joinpath(temp,"population_density_hilo.json")
        metadata=JSON.parsefile(metadata_path)
        metadata["cartogram"]=basename(destination)*"/cartogram_weights_hilo.arrow"
        OWIDLayout.write_json_atomic(metadata_path,metadata)
        checks["source_checks_sha256"]=OWIDLayout.file_digest(joinpath(source,"checks.json"))
        checks["mapping_job_sha256"]=OWIDLayout.file_digest(jobpath)
        checks["files"]=Dict(f=>OWIDLayout.file_digest(joinpath(temp,f)) for f in readdir(temp))
        OWIDLayout.write_json_atomic(joinpath(temp,"checks.json"),checks)
        mv(temp,destination)
    finally
        ispath(temp) && rm(temp;recursive=true)
    end
    destination
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==2 || error("Usage: publish.jl MAPPING_DIR NEW_H3_MON_DATASET_DIR")
    println("Published: ",publish_mapping(ARGS...))
end
