using Serialization,CSV,DataFrames,Statistics,LinearAlgebra,TOML,SHA
include("diagnostics.jl")
include("mobile_export.jl")
const ME=MobileExport
function part_stats(part,factor)
    (;meta,source,target,weights)=part;n=length(meta.ids);m=length(meta.targets)
    mass=zeros(m);q=zeros(3,m);a=zeros(n);sx=zeros(n);sy=zeros(n);second=zeros(n)
    groups=[Float64[] for _ in 1:n]
    for e in eachindex(weights)
        i,j=source[e],target[e];w=weights[e];x,y,_=meta.targets[j]
        mass[j]+=w;a[i]+=w;sx[i]+=w*x;sy[i]+=w*y;second[i]+=w*(x*x+y*y);push!(groups[i],w)
        for l in 1:3;q[l,j]+=w*meta.xyz[l,i];end
    end
    q./=transpose(mass)
    counts=[searchsortedfirst(cumsum(sort!(groups[i];rev=true)),.995a[i]) for i in 1:n]
    variance=max.(second .- (sx.^2 .+ sy.^2)./a,0.)
    small=a .<= maximum(mass);small_count=count(small)
    (;q,ratio995=mean(counts),spatial_rms_coarse=sqrt(sum(variance)/(4factor^2*sum(a))),mass,
        low_population_sources=small_count,low_population_ratio995=small_count==0 ? 0. : mean(counts[small]),
        low_population_spatial_rms_coarse=small_count==0 ? 0. : sqrt(mean((variance./a)[small])/(4factor^2)))
end
function edges(countries,borders)
    lookup=Dict{Tuple{Int,Int},Tuple{Int,Int}}();mixed=Set{Tuple{Int,Int}}()
    for (k,c) in enumerate(countries),(j,r) in enumerate(eachrow(c.target))
        key=(r.x,r.y);haskey(lookup,key)&&push!(mixed,key);lookup[key]=(k,j)
    end
    foreach(k->delete!(lookup,k),mixed)
    result=NTuple{4,Int}[]
    for ((x,y),(k,j)) in lookup,pos in ((x+2,y),(x,y+2))
        haskey(lookup,pos)||continue;l,t=lookup[pos]
        (k==l||minmax(countries[k].code,countries[l].code) in borders)&&push!(result,(k,j,l,t))
    end
    result
end
function geometry(countries,borders)
    es=edges(countries,borders);internal=Float64[];cross=Float64[]
    for (k,j,l,t) in es
        d2=6371^2*sum(abs2,countries[k].xyz[:,j]-countries[l].xyz[:,t])
        push!(k==l ? internal : cross,d2)
    end
    (;internal_edges=length(internal),cross_edges=length(cross),internal_mean_rms_km=isempty(internal) ? 0. : sqrt(mean(internal)),
        cross_mean_rms_km=isempty(cross) ? 0. : sqrt(mean(cross)))
end
function main()
    length(ARGS)==5||error("usage: native_quality.jl FIT GUIDES FACTOR BORDER_CSV NEW_OUTPUT")
    root,guides,f,borderfile,out=ARGS;factor=parse(Int,f);ispath(out)&&error("output exists");mkpath(out)
    borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(CSV.read(borderfile,DataFrame)))
    countries=NamedTuple[];references=NamedTuple[];reports=NamedTuple[]
    codes=sort(deserialize(joinpath(guides,"codes.jls")))
    paths=[joinpath(root,"country-$code","part.jls") for code in codes]
    digest()=bytes2hex(sha256(join([bytes2hex(open(sha256,path)) for path in paths],"")))
    parts_hash=digest()
    for code in codes
        part=deserialize(joinpath(root,"country-$code","part.jls"));stats=part_stats(part,factor)
        guide=deserialize(joinpath(guides,"country-$code.jls"));reference=ME.reference_stats(guide)
        target=DataFrame(x=[x for (x,y,c) in part.meta.targets],y=[y for (x,y,c) in part.meta.targets])
        oldtarget=DataFrame(x=[x for (x,y,c) in guide.meta.targets],y=[y for (x,y,c) in guide.meta.targets])
        push!(countries,(;code,target,xyz=stats.q));push!(references,(;code,target=oldtarget,xyz=reference.target_xyz))
        # Compare coarse means after subdivision, not individual fine cells.
        lookup=Dict((x,y,c)=>j for (j,(x,y,c)) in enumerate(part.meta.targets));coarse=zeros(size(reference.target_xyz))
        for (j,(x,y,c)) in enumerate(guide.meta.targets)
            children=[lookup[(factor*x+2ix-factor-1,factor*y+2iy-factor-1,c)] for ix in 1:factor for iy in 1:factor]
            mass=stats.mass[children];coarse[:,j]=stats.q[:,children]*mass/sum(mass)
        end
        shifts=6371sqrt.(vec(sum(abs2,coarse.-reference.target_xyz;dims=1)))
        push!(reports,(;code,sources=length(part.meta.ids),targets=length(part.meta.targets),rows=length(part.weights),
            stats.ratio995,stats.spatial_rms_coarse,stats.low_population_sources,
            stats.low_population_ratio995,stats.low_population_spatial_rms_coarse,
            capacity_lower995=mean(max.(1.,ceil.(.995 .* part.meta.population./(maximum(stats.mass)*sum(part.meta.population)) .- 1e-9))),
            coarse_mean_rms_shift_km=sqrt(mean(abs2,shifts)),coarse_mean_max_shift_km=maximum(shifts)))
    end
    CSV.write(joinpath(out,"countries.csv"),reports)
    for (name,cs) in (("native",countries),("reference",references))
        CSV.write(joinpath(out,"$name-orientation.csv"),ContinuityDiagnostics.orientations(cs,fill(nothing,length(cs));moments=(c,p)->c.xyz))
    end
    parts_hash==digest()||error("quality input changed")
    report=Dict("factor"=>factor,"parts_sha256"=>parts_hash,"border_sha256"=>bytes2hex(open(sha256,borderfile)),"root"=>abspath(root),"native"=>Dict(string(k)=>v for (k,v) in pairs(geometry(countries,borders))),
        "reference"=>Dict(string(k)=>v for (k,v) in pairs(geometry(references,borders))),
        "sources"=>sum(r.sources for r in reports),"rows"=>sum(r.rows for r in reports),
        "ratio995"=>sum(r.sources*r.ratio995 for r in reports)/sum(r.sources for r in reports),
        "capacity_lower995"=>sum(r.sources*r.capacity_lower995 for r in reports)/sum(r.sources for r in reports),
        "low_population_sources"=>sum(r.low_population_sources for r in reports),
        "low_population_ratio995"=>sum(r.low_population_sources*r.low_population_ratio995 for r in reports)/max(1,sum(r.low_population_sources for r in reports)))
    open(io->TOML.print(io,report),joinpath(out,"geometry.toml"),"w");println(report)
end
if abspath(PROGRAM_FILE)==@__FILE__
    main()
end
