"""Export checked fragment transport to the H3-MON hi/lo Arrow format."""
function export_mapping(mapping,sources,targets,output;codes=code_table(joinpath(@__DIR__,"../config/country-codes.csv")),title="Population density")
    ispath(output) && error("Use a new export directory")
    checks=check_mapping(mapping,sources,targets)
    source=Dict(r.id=>r for r in eachrow(sources))
    target=Dict((r.x,r.y)=>r for r in eachrow(targets))
    countries=sort!(unique(String.(targets.country)));codes=copy(codes)
    special=setdiff(countries,keys(codes));nextcode=max(1000,maximum(values(codes);init=999)+1)
    for (i,country) in enumerate(special);codes[country]=nextcode+i-1;end
    length(unique(codes[c] for c in countries))==length(countries) || error("Duplicate country codes")
    parents=Dict{UInt64,Float64}();masses=Dict{Tuple{UInt64,Int,Int},Float64}();totals=Dict(p=>0.0 for p in keys(target))
    for s in eachrow(sources);parents[s.h3]=get(parents,s.h3,0.)+s.value;end
    for r in eachrow(mapping)
        s=source[r.id];key=(s.h3,Int(r.x),Int(r.y));mass=r.weight*s.value
        masses[key]=get(masses,key,0.)+mass;totals[r.x,r.y]+=mass
    end
    records=DataFrame(index_lower=UInt32[],index_upper=UInt32[],x=Int32[],y=Int32[],weight=Float64[],
        weight_mean=Float64[],population=Float64[],code=Int32[],label=Union{Missing,String}[],prominence=Union{Missing,Float64}[])
    retained=Dict(h=>0. for h in keys(parents));means=Dict(p=>0. for p in keys(target))
    for ((h,x,y),mass) in sort!(collect(masses);by=first)
        weight=mass/parents[h];mean=mass/totals[x,y]
        push!(records,(UInt32(h&0xffffffff),UInt32(h>>32),Int32(2x),Int32(-2y),weight,mean,
            parents[h],Int32(codes[target[x,y].country]),missing,missing))
        retained[h]+=weight;means[x,y]+=mean
    end
    all(isapprox(v,1.;atol=1e-9,rtol=0) for v in [values(retained)...,values(means)...]) || error("Export weights do not sum to one")
    density=DataFrame([(index_lower=UInt32(h&0xffffffff),index_upper=UInt32(h>>32),value=p/H3.API.cellAreaKm2(h))
        for (h,p) in sort!(collect(parents);by=first)])
    all(v->isfinite(v)&&v>0,density.value) || error("Invalid density")
    parent=dirname(abspath(output));mkpath(parent);temp=mktempdir(parent;prefix="export-")
    try
        Arrow.write(joinpath(temp,"cartogram_weights_hilo.arrow"),records;file=true)
        Arrow.write(joinpath(temp,"population_density_hilo.arrow"),density;file=true)
        CSV.write(joinpath(temp,"country-codes.csv"),[(country=c,code=codes[c],kind=c in special ? "categorical" : "input") for c in countries])
        metadata=Dict("t"=>title,"c"=>"Matched Kontur population / full H3 cell area in km². Population year not declared. No city labels.",
            "cartogram"=>basename(output)*"/cartogram_weights_hilo.arrow","colourScheme"=>"interpolateViridis",
            "colourScale"=>"quantile","quantileSource"=>"cartogram")
        open(io->JSON.print(io,metadata),joinpath(temp,"population_density_hilo.json"),"w")
        merge!(checks,Dict("h3_parents"=>length(parents),"mapping_rows"=>nrow(records),
            "files"=>Dict(f=>file_digest(joinpath(temp,f)) for f in readdir(temp))))
        open(io->JSON.print(io,checks),joinpath(temp,"checks.json"),"w")
        mv(temp,output)
    finally
        ispath(temp) && rm(temp;recursive=true)
    end
    checks
end

# Publish checkpoint metadata only after the corresponding file is complete.
function write_json_atomic(path,value)
    temp=path*".tmp"
    open(io->JSON.print(io,value),temp,"w")
    mv(temp,path;force=true)
end

function mapping_signature(build,resolution,backend)
    root=normpath(joinpath(@__DIR__,".."))
    files=[joinpath(build,"build.json")]
    options=get(JSON.parsefile(first(files)),"options",Dict())
    for key in ("country_codes","scope_crosswalk")
        path=get(options,key,nothing)
        isnothing(path) || push!(files,path)
    end
    for dir in (joinpath(build,"sources"),joinpath(build,"layout"),joinpath(root,"src"),joinpath(root,"../src"))
        append!(files,[joinpath(dir,f) for f in readdir(dir) if isfile(joinpath(dir,f))])
    end
    append!(files,[joinpath(root,"Project.toml"),joinpath(root,"Manifest.toml"),joinpath(root,"config/country-codes.csv")])
    Dict("resolution"=>resolution,"backend"=>string(typeof(backend)),"julia"=>string(VERSION),
        "files"=>Dict(abspath(p)=>file_digest(p) for p in files))
end

"""Fit a completed layout build. Resume only with identical inputs and code."""
function fit_export(build,output;resolution=5,backend=KA.CPU(),resume=false)
    signature=mapping_signature(build,resolution,backend)
    jobpath=joinpath(output,"mapping-job.json")
    if ispath(output)
        resume || error("Use a new mapping directory, or explicitly resume")
        job=JSON.parsefile(jobpath)
        job["signature"]==signature || error("Inputs, code, or backend changed; use a new mapping directory")
        get(job,"complete",false) && error("Mapping already complete")
    else
        mkpath(output)
        job=Dict{String,Any}("signature"=>signature,"complete"=>false,"shards"=>Dict{String,Any}())
        write_json_atomic(jobpath,job)
    end
    inputs=mapping_inputs(build;resolution);sources,targets=inputs.sources,inputs.targets
    CSV.write(joinpath(output,"sources.csv"),sources);CSV.write(joinpath(output,"targets.csv"),targets)
    write_json_atomic(joinpath(output,"population-audit.json"),inputs.audit)
    mkpath(joinpath(output,"shards"));mappings=DataFrame[]
    for (i,group) in enumerate(sort!(unique(sources.group_id)))
        s=sources[sources.group_id.==group,:];t=targets[targets.group_id.==group,:]
        file=joinpath(output,"shards","$i.arrow")
        if haskey(job["shards"],group)
            job["shards"][group]["sha256"]==file_digest(file) || error("Changed mapping shard")
            mapping=DataFrame(Arrow.Table(file));check_mapping(mapping,s,t)
        else
            println("Fit ",group,": ",nrow(s)," source fragments, ",nrow(t)," tiles");flush(stdout)
            mapping,checks=fit_pool(s,t;backend)
            Arrow.write(file*".tmp",mapping;file=true);mv(file*".tmp",file;force=true)
            job["shards"][group]=Dict("sha256"=>file_digest(file),"checks"=>checks)
            write_json_atomic(jobpath,job)
        end
        push!(mappings,mapping)
    end
    # If a process stopped after export, verify its files before completing.
    exported=joinpath(output,"h3-mon")
    if ispath(exported)
        checks=JSON.parsefile(joinpath(exported,"checks.json"))
        all(file_digest(joinpath(exported,f))==hash for (f,hash) in checks["files"]) || error("Changed export")
    else
        record=JSON.parsefile(joinpath(build,"build.json"))
        codepath=get(get(record,"options",Dict()),"country_codes",joinpath(@__DIR__,"../config/country-codes.csv"))
        checks=export_mapping(vcat(mappings...),sources,targets,exported;codes=code_table(codepath))
    end
    job["export"]=checks;job["complete"]=true
    write_json_atomic(jobpath,job)
    job
end
