module BoundedReduction
using Serialization
const CODE=Dict(name=>read(joinpath(@__DIR__,name)) for name in ("bounded.jl","moments.jl"))
include("moments.jl")
const MR=MomentReduction
const MAX_INLINE=1024

mutable struct Worker
    root::String
    directory::String
    process::Union{Nothing,Base.Process}
    program::String
end
function Worker(root)
    snapshot=joinpath(root,"worker-code");mkpath(snapshot)
    for (name,bytes) in CODE
        path=joinpath(snapshot,name)
        if isfile(path)
            read(path)==bytes || error("worker code changed")
        else
            write(path,bytes)
        end
    end
    return Worker(root,"",nothing,abspath(joinpath(snapshot,"bounded.jl")))
end

function stop!(worker;hard=false)
    process=worker.process
    isnothing(process) && return
    if process_running(process)
        if !hard
            touch(joinpath(worker.directory,"stop"))
            timedwait(()->!process_running(process),3.;pollint=.05)
        end
        process_running(process) && kill(process,Base.SIGKILL)
    end
    wait(process);worker.process=nothing
    return nothing
end

function start!(worker)
    !isnothing(worker.process) && process_running(worker.process) && return
    mkpath(worker.root)
    worker.directory=mktempdir(worker.root;prefix="worker-",cleanup=false)
    project=dirname(Base.active_project())
    cmd=`$(Base.julia_cmd()) --startup-file=no --threads=1 --project=$project $(worker.program) $(worker.directory)`
    log=joinpath(worker.directory,"process.log")
    worker.process=run(pipeline(addenv(cmd,"OPENBLAS_NUM_THREADS"=>"1");stdout=log,stderr=log);wait=false)
    return nothing
end

function execute!(worker,job;seconds)
    seconds>0 || error("invalid worker deadline")
    start!(worker)
    request=joinpath(worker.directory,"request.jls");response=joinpath(worker.directory,"response.jls")
    serialize(request*".tmp",job);mv(request*".tmp",request)
    ready=timedwait(()->isfile(response) || !process_running(worker.process),seconds;pollint=min(.05,max(.001,seconds/2)))
    if ready!=:ok
        stop!(worker;hard=true)
        error("block exceeded $seconds seconds; failed input: $(worker.directory)")
    end
    isfile(response) || error("worker exited; see $(worker.directory)/process.log")
    result=deserialize(response);rm(response)
    result.ok || error(result.error)
    return result.value
end

function worker_loop(directory)
    request=joinpath(directory,"request.jls");active=joinpath(directory,"active.jls")
    response=joinpath(directory,"response.jls")
    while !isfile(joinpath(directory,"stop"))
        if !isfile(request)
            sleep(.02);continue
        end
        mv(request,active)
        job=deserialize(active)
        result=try
            (;ok=true,value=job.f(job.args...;job.kwargs...))
        catch err
            (;ok=false,error=sprint(showerror,err,catch_backtrace()))
        end
        serialize(response*".tmp",result);mv(response*".tmp",response)
        rm(active)
    end
end

function compact_block(data,rows)
    sources=unique(data.index.source[rows]);targets=unique(data.index.target[rows])
    smap=Dict(s=>Int32(i) for (i,s) in enumerate(sources))
    tmap=Dict(t=>Int32(i) for (i,t) in enumerate(targets))
    labels=Dict(smap[s]=>name for (s,name) in data.meta.labels if haskey(smap,s))
    anchors=Dict(data.index.source_rows[data.index.source_ptr[s]]=>smap[s] for s in sources if haskey(data.meta.labels,s))
    anchor_rows=zeros(Int32,length(sources))
    for (k,r) in enumerate(rows)
        haskey(anchors,r) && (anchor_rows[anchors[r]]=k)
    end
    meta=(;ids=data.meta.ids[sources],population=data.meta.population[sources],
        xyz=data.meta.xyz[:,sources],targets=data.meta.targets[targets],labels)
    # The solver only needs this source index for the original label-anchor lookup.
    index=(;source=Int32[smap[data.index.source[r]] for r in rows],
        target=Int32[tmap[data.index.target[r]] for r in rows],
        source_ptr=collect(eachindex(sources)),source_rows=anchor_rows)
    return (;meta,index,weight=data.weight[rows]),targets
end

function reduce_block!(worker,data,rows,weights,target_mass;limit=30.,floors=nothing,max_inline=MAX_INLINE,kwargs...)
    if length(rows)<=max_inline
        return MR.reduce_block(data,rows,weights,target_mass;limit,floors,kwargs...)
    end
    block,targets=compact_block(data,rows)
    args=(block,Int32.(eachindex(rows)),weights,target_mass[targets])
    options=(;limit,floors=isnothing(floors) ? nothing : floors[rows],kwargs...)
    result=execute!(worker,(;f=MR.reduce_block,args,kwargs=options);seconds=limit+20)
    return merge(result,(;rows=rows[result.rows]))
end
end

if abspath(PROGRAM_FILE)==@__FILE__
    BoundedReduction.worker_loop(only(ARGS))
end
