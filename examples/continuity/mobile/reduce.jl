# Run with --project=examples/continuity/mobile. Input is a country_data cache.
using Serialization, Dates, SHA
include("../mobile_export.jl")
include("bounded.jl")
const ME=MobileExport
const MR=BoundedReduction.MomentReduction

function save_checkpoint(path,value)
    serialize(path*".tmp",value)
    mv(path*".tmp",path;force=true)
end

function checked_checkpoint(path,data,rows,weights,reference;target_retained=0.,metadata...)
    summary=ME.evaluate(data,rows,reference;weights)
    validate(summary;target_retained)
    save_checkpoint(path,(;rows,weights,target_retained,summary,metadata...))
    return summary
end

function reduce_country(input,out;stages=[(128,64),(256,128),(512,256),(1024,512),(2048,1024)],limit=30.,seed=nothing,target_retained=0.,fixed_floors=false)
    mkpath(out)
    config=(;input=abspath(input),bytes=filesize(input),modified=mtime(input),stages,limit,target_retained,fixed_floors,
        seed=isnothing(seed) ? nothing : (abspath(seed),bytes2hex(sha256(read(seed)))), 
        code=[bytes2hex(sha256(read(joinpath(@__DIR__,file)))) for file in ("reduce.jl","bounded.jl","moments.jl","../mobile_export.jl")])
    config_path=joinpath(out,"config.jls")
    if isfile(config_path)
        deserialize(config_path)==config || error("checkpoint input or code changed")
    else
        isempty(readdir(out)) || error("output has no checkpoint configuration")
        save_checkpoint(config_path,config)
    end
    data=deserialize(input);reference=ME.reference_stats(data)
    floors=ME.target_floor_rows(data,target_retained)
    source_order=sortperm(data.meta.ids)
    target_order=sortperm(data.meta.targets)
    srank=invperm(source_order);trank=invperm(target_order)
    if isnothing(seed)
        rows=Int32.(eachindex(data.weight));weights=copy(data.weight)
    else
        saved=deserialize(seed);rows,weights=saved.rows,saved.weights
        length(unique(rows))==length(rows) || error("duplicate seed rows")
        validate(ME.evaluate(data,rows,reference;weights);target_retained)
        if !isnothing(floors)
            present=falses(length(data.weight));present[rows].=true
            all(present[floors]) || error("seed lacks protected rows")
            all(!floors[r] || weights[k]>=data.weight[r]-1e-8 for (k,r) in enumerate(rows)) || error("seed lost a protected weight")
        end
    end
    worker=BoundedReduction.Worker(out)
    try
    for (stage,(sb,tb)) in enumerate(stages)
        path=joinpath(out,"stage-$stage.jls")
        if isfile(path)
            saved=deserialize(path)
            saved.source_block==sb && saved.target_block==tb || error("checkpoint settings changed")
            rows,weights=saved.rows,saved.weights
            continue
        end
        nt=cld(length(trank),tb)
        groups=[(cld(srank[data.index.source[r]],sb)-1)*nt+cld(trank[data.index.target[r]],tb) for r in rows]
        order=sortperm(groups);newrows=Int32[];newweights=Float64[]
        failures=0;blocks=0;seconds=0.;start=time();first=1;last_checkpoint=start
        working=joinpath(out,"working.jls")
        while first<=length(order)
            last=first
            while last<length(order) && groups[order[last+1]]==groups[order[first]]
                last+=1
            end
            positions=view(order,first:last);rr=rows[positions];ww=weights[positions]
            if blocks>0 && length(rr)>BoundedReduction.MAX_INLINE && time()-last_checkpoint>30
                remaining=view(order,first:length(order))
                checked_checkpoint(working,data,vcat(newrows,rows[remaining]),vcat(newweights,weights[remaining]),reference;
                    target_retained,stage,source_block=sb,target_block=tb,blocks,failures,seconds,complete=false)
                last_checkpoint=time()
            end
            result=try
                BoundedReduction.reduce_block!(worker,data,rr,ww,reference.target_mass;density=true,limit,floors,fixed_floors)
            catch err
                err isa InterruptException && rethrow()
                failures+=1
                println((;time=now(UTC),stage,block=blocks+1,error=sprint(showerror,err)));flush(stdout)
                (;rows=rr,weights=ww,seconds=0.)
            end
            append!(newrows,result.rows);append!(newweights,result.weights)
            seconds+=result.seconds;blocks+=1;first=last+1
            if blocks%100==0
                println((;time=now(UTC),stage,blocks,processed=last,total=length(rows),kept=length(newrows),failures));flush(stdout)
            end
        end
        summary=checked_checkpoint(path,data,newrows,newweights,reference;
            target_retained,stage,source_block=sb,target_block=tb,failures,blocks,seconds,complete=true)
        isfile(working) && rm(working)
        println((;time=now(UTC),stage,elapsed=time()-start,failures,blocks,summary));flush(stdout)
        rows,weights=newrows,newweights
        GC.gc()
    end
    return nothing
    finally
        BoundedReduction.stop!(worker)
    end
end

function validate(summary;target_retained=0.)
    summary.target_tv_max<=1-target_retained+1e-5 || error("target variation bound failed")
    summary.source_sum_error<=1e-5 && summary.target_mass_error_max<=1e-5 &&
        summary.forward_max<=.001 && summary.inverse_km_max<=.001 || error("country validation failed: $summary")
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==2 || error("usage: reduce.jl COUNTRY_CACHE OUTPUT_DIRECTORY")
    reduce_country(ARGS...)
end
