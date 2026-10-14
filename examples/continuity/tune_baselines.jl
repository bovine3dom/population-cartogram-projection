# Calibrate compact baseline temperatures without changing any published data.
using Serialization, Dates, SHA, TOML, oneAPI
include("experiment.jl")
const CE=ContinuityExperiment
using .CE: CSV, DataFrame

function tune_baselines(input,pose_file,out,codes=Int[])
    oneAPI.functional() || error("oneAPI is unavailable")
    source=joinpath(input,"countries.jls")
    countries=deserialize(source)
    isempty(codes) || (countries=filter(c->c.code in codes,countries))
    isempty(countries) && error("no countries selected")
    isempty(codes) || Set(getproperty.(countries,:code))==Set(codes) || error("unknown country code")
    angles=pose_file=="-" ? Dict{Int,Int}() :
        Dict(r.code=>r.angle for r in eachrow(CSV.read(pose_file,DataFrame)))
    pose_file=="-" || all(haskey(angles,c.code) for c in countries) || error("missing pose")
    cache_bytes=parse(Int,get(ENV,"CONTINUITY_COMPACT_CACHE_BYTES",string(512*1024^2)))
    multiplier=parse(Float64,get(ENV,"CONTINUITY_TUNE_MULTIPLIER","2"))
    cache_bytes>=0 && isfinite(multiplier) && multiplier>0 || error("invalid limits")
    digest(path)=bytes2hex(open(sha256,path))
    files=["experiment.jl","compact.jl","primal.jl","eta_tuning.jl","sharpness.jl","tune_baselines.jl"]
    config=Dict("input_sha256"=>digest(source),"poses_sha256"=>(pose_file=="-" ? "none" : digest(pose_file)),
        "codes"=>getproperty.(countries,:code),"cache_bytes"=>cache_bytes,"multiplier"=>multiplier,
        "code_sha256"=>Dict(file=>digest(joinpath(@__DIR__,file)) for file in files))
    config_path=joinpath(out,"config.toml")
    if ispath(out)
        isfile(config_path) && TOML.parsefile(config_path)==config || error("output configuration differs")
    else
        mkpath(out)
        open(io->TOML.print(io,config),config_path,"w")
        write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\n"*read(`git rev-parse HEAD`,String))
    end
    backend=oneAPI.oneAPIBackend();selected=Dict();reports=NamedTuple[]
    for c in sort(countries;by=c->length(c.b))
        dir=joinpath(out,string(c.code));mkpath(dir)
        path=joinpath(dir,"selected.jls")
        if isfile(path)
            selected[c.code]=deserialize(path)
        else
            angle=get(angles,c.code,0)
            posed=merge(c,(;problem=CE.pose_problem(c,angle)))
            records=NamedTuple[]
            callback=function(record,result)
                push!(records,record)
                isnothing(result) || CE.checkpoint(joinpath(dir,"eta-$(record.eta).jls"),result)
                CSV.write(joinpath(dir,"stages.csv"),DataFrame(records))
                println(now(UTC)," code=",c.code," angle=",angle," ",record);flush(stdout)
            end
            tuned=CE.compact_tune(posed,backend;target_rows=multiplier*(length(c.a)+length(c.b)),
                tolerance=1e-4,cache_bytes,stage_callback=callback)
            CE.checkpoint(path,tuned);selected[c.code]=tuned
        end
        entry=selected[c.code]
        push!(reports,(;code=c.code,angle=get(angles,c.code,0),eta=entry.eta,
            sources=length(c.a),targets=length(c.b),rows=entry.support.rows,
            target_rows=entry.target_rows,target_met=entry.target_met,
            ratio=entry.support.rows/length(c.a),marginal_error=entry.result.marginal_error))
        CSV.write(joinpath(out,"selection.csv"),DataFrame(reports));GC.gc()
    end
    CE.checkpoint(joinpath(out,"countries.jls"),countries)
    CE.checkpoint(joinpath(out,"baseline.jls"),[selected[c.code].result.plan for c in countries])
    CSV.write(joinpath(out,"country-etas.csv"),DataFrame(code=getproperty.(countries,:code),
        eta=[selected[c.code].eta for c in countries]))
    write(joinpath(out,"tuning-complete.txt"),"Completed $(length(countries)) countries: $(now(UTC)) UTC\nInspect selection.csv for unmet support targets.\n")
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)>=3 || error("usage: tune_baselines.jl INPUT_ROOT POSES_CSV_OR_DASH NEW_OUTPUT [COUNTRY_CODES...]")
    tune_baselines(ARGS[1:3]...,parse.(Int,ARGS[4:end]))
end
