#!/usr/bin/env julia
# Adapt the continuity experiment to fixed island groups, not whole countries.
using JSON
include(joinpath(@__DIR__,"..","continuity","planet.jl"))

function prepare_groups(original,contacts,out;expected_tiles=55000)
    ispath(out) && error("Output exists")
    sources=CSV.read(joinpath(original,"sources.csv"),DataFrame)
    targets=CSV.read(joinpath(original,"targets.csv"),DataFrame)
    names=sort!(unique(String.(targets.group_id)));codes=Dict(g=>i for (i,g) in enumerate(names))
    ownership=Dict((r.x,r.y)=>String(r.group_id) for r in eachrow(targets))
    length(ownership)==nrow(targets)==expected_tiles || error("Unexpected tile count or duplicate coordinates")
    geographic=Set(minmax(String(r.a),String(r.b)) for r in eachrow(CSV.read(contacts,DataFrame)) if r.a in names && r.b in names)
    touching=Set{Tuple{String,String}}()
    for ((x,y),g) in ownership, p in ((x+1,y),(x,y+1))
        other=get(ownership,p,g);g==other || push!(touching,minmax(g,other))
    end
    fitted=intersect(geographic,touching);active=Set(v for pair in fitted for v in pair)
    isempty(active) && error("No real component border contacts")
    countries=NamedTuple[]
    for g in names
        g in active || continue
        println("Preparing $g");flush(stdout)
        source=filter(:group_id=>(==(g)),sources)
        target=select(filter(:group_id=>(==(g)),targets),:x,:y)
        target.x .*= 2;target.y .*= -2
        allunique(source.id) || error("Duplicate fragment ID")
        problem=CE.PCP._prepare_problem(target,source)
        centres=H3.API.cellToLatLng.([parse(UInt64,last(rsplit(id,':';limit=2))) for id in source.id])
        xyz=permutedims(hcat([cos(c.lat)*cos(c.lng) for c in centres],[cos(c.lat)*sin(c.lng) for c in centres],[sin(c.lat) for c in centres]))
        a=source.value./sum(source.value);b=fill(1/nrow(target),nrow(target))
        push!(countries,(;code=codes[g],source,target,problem,cost=CE.GeometryCost(problem),xyz,a,b))
    end
    mkpath(out)
    for f in ("groups.csv","sources.csv","targets.csv");cp(joinpath(original,f),joinpath(out,f));end
    cp(joinpath(original,"labels"),joinpath(out,"labels"))
    cp(contacts,joinpath(out,"geographic-contacts.csv"))
    CSV.write(joinpath(out,"group-codes.csv"),DataFrame(group_id=names,code=[codes[g] for g in names],fitted=[g in active for g in names]))
    CSV.write(joinpath(out,"contacts.csv"),DataFrame([(;a,b,geographic=(a,b) in geographic,touching=(a,b) in touching,fitted=(a,b) in fitted) for (a,b) in sort!(collect(union(geographic,touching)))]))
    borders=Set(minmax(codes[a],codes[b]) for (a,b) in fitted)
    CE.checkpoint(joinpath(out,"countries.jls"),countries);CE.checkpoint(joinpath(out,"borders.jls"),borders)
    files=[joinpath(original,f) for f in ("groups.csv","sources.csv","targets.csv")]
    push!(files,contacts,@__FILE__)
    open(io->JSON.print(io,Dict("original"=>abspath(original),"commit"=>strip(read(`git rev-parse HEAD`,String)),"files"=>Dict(abspath(p)=>bytes2hex(open(sha256,p)) for p in files),"active_groups"=>length(active),"border_pairs"=>length(fitted),"policy"=>"Component fragments stay in their assigned group. Only exact represented-component geographic contacts are eligible. Base costs retain native population-weighted projected coordinates; continuity moments use H3-5 parent centres."),2),joinpath(out,"provenance.json"),"w")
    println("Prepared $(length(countries)) active groups and $(length(borders)) real border pairs")
end

function seed_groups(out,tuned)
    isfile(joinpath(tuned,"tuning-complete.txt")) || error("Calibration incomplete")
    countries=deserialize(joinpath(out,"countries.jls"));plans=deserialize(joinpath(tuned,"baseline.jls"))
    borders=deserialize(joinpath(out,"borders.jls"));edges=CE.graph(countries;borders)
    factors=local_factors(countries,plans,edges)
    etas=Dict(r.code=>r.eta for r in eachrow(CSV.read(joinpath(tuned,"country-etas.csv"),DataFrame)))
    CE.run_case(countries,oneAPI.oneAPIBackend(),joinpath(out,"fit");initial_plans=plans,compact=true,borders,
        border_factors=factors,strength=15.0length(countries),fold_strength=.5length(countries),country_etas=etas,
        border_share=.25,scale_km=900.,form=:distribution,saturating=false,proximal=.01,max_damping=1.,
        outer_steps=0,coordinate=true,interior_limit=4.,spread_limit=1.25,inner_tolerance=1e-4,
        export_arrow=false,save_passes=true,compact_retry_factor=256)
end

function extract_groups(original,out,fit)
    isfile(joinpath(fit,"research-fit-complete.txt")) || error("Border refit incomplete")
    countries=deserialize(joinpath(out,"countries.jls"));plans=deserialize(joinpath(fit,"fit","candidate.jls"))
    code_groups=Dict(r.code=>String(r.group_id) for r in eachrow(CSV.read(joinpath(out,"group-codes.csv"),DataFrame)))
    active=Set(c.code for c in countries);raw=joinpath(out,"raw");mkpath(raw)
    for (code,group) in code_groups
        code in active && continue
        dest=joinpath(raw,group);ispath(dest) && continue
        cp(joinpath(original,"balanced",group),dest)
        write(joinpath(dest,"complete.txt"),"Unchanged checked island group\n")
    end
    for (c,p) in zip(countries,plans)
        group=code_groups[c.code];dest=joinpath(raw,group)
        isfile(joinpath(dest,"complete.txt")) && continue
        CE.compact_stats!(p,c)
        maximum(abs.(p.stats.source./c.a.-1))<=1e-8 || error("Full-plan source mass failed")
        sum(abs.(p.stats.target.-c.b))<=1e-4 && maximum(abs.(p.stats.target./c.b.-1))<=.001 || error("Full-plan target mass failed")
        mapping=DataFrame(x=Int[],y=Int[],id=String[],weight=Float64[],weight_mean=Float64[])
        totals=zeros(length(c.b));block=max(1,fld(1_000_000,length(c.b)))
        for first in 1:block:length(c.a)
            indices=first:min(first+block-1,length(c.a));mass=exp.(CE.logblock(p,indices))
            for (i,s) in enumerate(indices)
                weights=vec(mass[i,:]);weights./=sum(weights);order=sortperm(weights;rev=true)
                count=min(searchsortedfirst(cumsum(weights[order]),.9999999),length(order));chosen=order[1:count]
                retained=sum(weights[chosen])
                for j in chosen
                    w=weights[j]/retained;w>0 || continue
                    push!(mapping,(div(c.target.x[j],2),div(-c.target.y[j],2),c.source.id[s],w,0.))
                    totals[j]+=w*c.source.value[s]
                end
            end
        end
        positions=Dict((div(c.target.x[j],2),div(-c.target.y[j],2))=>j for j in eachindex(c.b))
        values=Dict(r.id=>r.value for r in eachrow(c.source))
        mapping.weight_mean=[r.weight*values[r.id]/totals[positions[(r.x,r.y)]] for r in eachrow(mapping)]
        expected=sum(c.source.value)/length(c.b)
        quality=DataFrame(x=div.(c.target.x,2),y=div.(-c.target.y,2),group_id=fill(group,length(c.b)),population=totals,expected_population=fill(expected,length(c.b)),relative_error=totals./expected.-1)
        minimum(totals)>0 || error("Empty extracted target")
        metadata=Dict("pooled"=>false,"source_population"=>sum(c.source.value),"retained_population"=>sum(totals),"retained_share"=>sum(totals)/sum(c.source.value),"cross_group_population"=>0.,"minimum_source_retained_share"=>1.,"maximum_source_retained_share"=>1.,"maximum_relative_target_error"=>maximum(abs,quality.relative_error),"coarse_sources"=>nrow(c.source),"targets"=>length(c.b),"groups"=>1,"retained_before_normalization"=>.9999999)
        temp=mktempdir(raw)
        CSV.write(joinpath(temp,"sources.csv"),c.source);CSV.write(joinpath(temp,"targets.csv"),select(quality,:x,:y,:group_id))
        CSV.write(joinpath(temp,"mapping.csv"),mapping);CSV.write(joinpath(temp,"target-quality.csv"),quality)
        open(io->JSON.print(io,metadata,2),joinpath(temp,"manifest.json"),"w")
        write(joinpath(temp,"complete.txt"),"Border-aware raw shard; balance and geometry audit required\n");mv(temp,dest)
        println("Extracted $group");flush(stdout)
    end
end

if abspath(PROGRAM_FILE)==@__FILE__
    mode=first(ARGS)
    mode=="prepare" ? prepare_groups(ARGS[2:4]...) : mode=="seed" ? seed_groups(ARGS[2:3]...) : mode=="extract" ? extract_groups(ARGS[2:4]...) : error("Usage: border_h3_groups.jl prepare ORIGINAL CONTACTS OUTPUT | seed OUTPUT TUNED | extract ORIGINAL OUTPUT FIT")
end
