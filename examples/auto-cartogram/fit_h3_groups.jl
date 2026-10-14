#!/usr/bin/env julia
# Fit each recorded island group independently; save restartable raw shards.
using Arrow, CSV, DataFrames, H3, JSON, SHA, Dates, oneAPI
include(joinpath(@__DIR__, "..", "..", "src", "PopulationCartogramProjection.jl"))
const PCP = PopulationCartogramProjection
sha(path)=bytes2hex(open(sha256,path))

function fit(cached_sources, groups_path, cells_path, output)
    oneAPI.functional() || error("oneAPI is not functional; no CPU fallback")
    inputs=Dict(p=>sha(p) for p in [cached_sources,groups_path,cells_path,@__FILE__])
    identity=joinpath(output,"fit-inputs.json")
    mkpath(output)
    if isfile(identity)
        JSON.parsefile(identity)==inputs || error("Restart inputs changed")
    else
        open(io->JSON.print(io,inputs,2),identity,"w")
    end
    groups=CSV.read(groups_path,DataFrame)
    sources=CSV.read(cached_sources,DataFrame)
    assignments=Dict(String(r.component_id)=>String(r.group_id) for r in eachrow(groups))
    allunique(sources.id) || error("Duplicate component/H3 source key")
    all(c->haskey(assignments,c),sources.component_id) || error("Unknown component")
    sources.group_id=[assignments[c] for c in sources.component_id]
    for r in eachrow(sources)
        component,parent=rsplit(r.id,':';limit=2)
        component==r.component_id || error("Source identity mismatch")
        id=parse(UInt64,parent)
        H3.API.isValidCell(id) && H3.API.getResolution(id)==5 || error("Expected H3-5")
    end
    native_totals=Dict(r.component_id=>r.value_sum for r in eachrow(combine(groupby(sources,:component_id),:value=>sum)))
    for r in eachrow(groups)
        isapprox(get(native_totals,r.component_id,0.),r.population;rtol=1e-12) || error("Component population mismatch: $(r.component_id)")
    end
    targets=CSV.read(cells_path,DataFrame);rename!(targets,:component_id=>:group_id)
    allunique(zip(targets.x,targets.y)) || error("Duplicate target")
    sg=groupby(sources,:group_id);tg=groupby(targets,:group_id)
    Set(sources.group_id)==Set(targets.group_id) || error("Source/target groups differ")
    CSV.write(joinpath(output,"sources.csv"),sources);CSV.write(joinpath(output,"targets.csv"),targets)
    mkpath(joinpath(output,"raw"))
    for r in sort(filter(:tiles=>(x->x>0),groups),:tiles;rev=true) |> eachrow
        group=String(r.component_id);dest=joinpath(output,"raw",group)
        isfile(joinpath(dest,"complete.txt")) && continue
        s=DataFrame(sg[(group_id=group,)]);t=DataFrame(tg[(group_id=group,)])
        nrow(t)==r.tiles || error("Tile budget mismatch")
        isapprox(sum(s.value),r.group_population;rtol=1e-12) || error("Group population mismatch")
        println("$(now(UTC)) $group: $(nrow(s)) sources -> $(nrow(t)) tiles");flush(stdout)
        started=time()
        if nrow(t)==1 || nrow(s)==1
            mapping=DataFrame([(;x=target.x,y=target.y,id=source.id,weight=1/nrow(t),weight_mean=source.value/sum(s.value)) for source in eachrow(s) for target in eachrow(t)])
        else
            screen=select(t,:x,:y);screen.y=-screen.y
            mapping=PCP.distribute(screen,select(s,:x,:y,:value,:id);backend=oneAPI.oneAPIBackend())
            mapping.y=-mapping.y
        end
        values=Dict(r.id=>r.value for r in eachrow(s));retained=Dict(id=>0. for id in s.id)
        totals=Dict((r.x,r.y)=>0. for r in eachrow(t))
        for row in eachrow(mapping)
            retained[row.id]+=row.weight;totals[(row.x,row.y)]+=values[row.id]*row.weight
        end
        expected=sum(s.value)/nrow(t)
        quality=DataFrame([(;x=row.x,y=row.y,group_id=group,population=totals[(row.x,row.y)],expected_population=expected,relative_error=totals[(row.x,row.y)]/expected-1) for row in eachrow(t)])
        metadata=Dict("pooled"=>false,"backend"=>"oneAPI","coarse_h3_resolution"=>5,"source_population"=>sum(s.value),"retained_population"=>sum(Base.values(totals)),"retained_share"=>sum(Base.values(totals))/sum(s.value),"cross_group_population"=>0.,"minimum_source_retained_share"=>minimum(Base.values(retained)),"maximum_source_retained_share"=>maximum(Base.values(retained)),"maximum_relative_target_error"=>maximum(abs,quality.relative_error),"coarse_sources"=>nrow(s),"targets"=>nrow(t),"groups"=>1,"elapsed_seconds"=>time()-started,"group"=>group)
        temp=mktempdir(joinpath(output,"raw"))
        CSV.write(joinpath(temp,"mapping.csv"),mapping);CSV.write(joinpath(temp,"sources.csv"),s);CSV.write(joinpath(temp,"targets.csv"),t);CSV.write(joinpath(temp,"target-quality.csv"),quality)
        open(io->JSON.print(io,metadata,2),joinpath(temp,"manifest.json"),"w")
        write(joinpath(temp,"complete.txt"),"raw transport only; balance and export checks required\n")
        mv(temp,dest)
        println("Saved $group in $(round(time()-started;digits=1)) s");flush(stdout)
        GC.gc()
    end
    write(joinpath(output,"fit-complete.txt"),"$(now(UTC)) UTC\n")
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==4 || error("Usage: fit_h3_groups.jl H3_5_COMPONENT_SOURCES.csv GROUPS.csv CELLS.csv OUTPUT")
    fit(ARGS...)
end
