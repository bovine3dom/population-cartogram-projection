# Browser export experiments. The fitted transport is not changed.
module MobileExport
using Arrow, CSV, H3, Statistics, Serialization

cellid(lo,hi)=(UInt64(hi)<<32)|UInt64(lo)

function metadata(lo,hi,x,y,pop,code,label)
    source_index=Dict{UInt64,Int32}();target_index=Dict{NTuple{3,Int},Int32}()
    ids=UInt64[];population=Float64[];codes=Int[];targets=NTuple{3,Int}[]
    labels=Dict{Int32,Vector{String}}()
    for r in eachindex(lo)
        id=cellid(lo[r],hi[r])
        s=get(source_index,id,Int32(0))
        if s==0
            s=Int32(length(ids)+1);source_index[id]=s
            push!(ids,id);push!(population,pop[r]);push!(codes,code[r])
        end
        population[s]==pop[r] && codes[s]==code[r] || error("ambiguous source")
        key=(Int(x[r]),Int(y[r]),Int(code[r]))
        if !haskey(target_index,key)
            push!(targets,key);target_index[key]=length(targets)
        end
        ismissing(label[r]) || push!(get!(labels,s,String[]),String(label[r]))
    end
    xyz=Matrix{Float64}(undef,3,length(ids))
    for (i,id) in enumerate(ids)
        H3.API.isValidCell(id) && H3.API.getResolution(id)==5 || error("expected H3-5")
        g=H3.API.cellToLatLng(id)
        xyz[:,i]=[cos(g.lat)*cos(g.lng),cos(g.lat)*sin(g.lng),sin(g.lat)]
    end
    return (;source_index,target_index,ids,population,codes,targets,xyz,
        labels=Dict(s=>join(unique(names),", ") for (s,names) in labels))
end

function group_rows(groups,n)
    counts=zeros(Int,n)
    for g in groups
        counts[g]+=1
    end
    all(>(0),counts) || error("coverage changed")
    ptr=vcat(1,1 .+ cumsum(counts));next=copy(ptr)
    rows=Vector{Int32}(undef,length(groups))
    for (r,g) in enumerate(groups)
        rows[next[g]]=r;next[g]+=1
    end
    return ptr,rows
end

function sort_groups!(rows,ptr,score)
    Threads.@threads for i in 1:length(ptr)-1
        slice=view(rows,ptr[i]:ptr[i+1]-1)
        issorted(slice;by=score,rev=true) || sort!(slice;by=score,rev=true)
    end
    return rows
end

function index_rows(lo,hi,x,y,code,w,meta)
    length(w)<=typemax(Int32) || error("too many rows")
    source=Vector{Int32}(undef,length(w));target=similar(source)
    for r in eachindex(w)
        isfinite(w[r]) && w[r]>0 || error("invalid weight")
        source[r]=meta.source_index[cellid(lo[r],hi[r])]
        target[r]=meta.target_index[(Int(x[r]),Int(y[r]),Int(code[r]))]
    end
    source_ptr,source_rows=group_rows(source,length(meta.ids))
    target_ptr,target_rows=group_rows(target,length(meta.targets))
    sort_groups!(source_rows,source_ptr,r->(@inbounds w[r]))
    sort_groups!(target_rows,target_ptr,r->(@inbounds w[r]*meta.population[source[r]]))
    return (;source,target,source_ptr,source_rows,target_ptr,target_rows)
end

function load_index(input,reference,cache)
    original=Arrow.Table(input)
    meta=metadata(original.index_lower,original.index_upper,original.x,original.y,
        original.population,original.code,original.label)
    table=Arrow.Table(reference)
    fingerprint=(abspath(reference),filesize(reference),mtime(reference),length(table.weight))
    if isfile(cache)
        saved=deserialize(cache)
        saved.fingerprint==fingerprint && saved.ids==meta.ids && saved.targets==meta.targets || error("stale index cache")
        index=saved.index
    else
        index=index_rows(table.index_lower,table.index_upper,table.x,table.y,table.code,table.weight,meta)
        mkpath(dirname(cache))
        serialize(cache,(;fingerprint,ids=meta.ids,targets=meta.targets,index))
    end
    return (;meta,index,weight=table.weight)
end

function country_data(data,code)
    (;meta,index,weight)=data
    sources=findall(==(code),meta.codes);targets=findall(t->t[3]==code,meta.targets)
    isempty(sources) && error("unknown country")
    smap=zeros(Int32,length(meta.ids));smap[sources]=1:length(sources)
    tmap=zeros(Int32,length(meta.targets));tmap[targets]=1:length(targets)
    rows=Vector{Int32}(undef,sum(index.source_ptr[s+1]-index.source_ptr[s] for s in sources));offset=0
    for s in sources
        count=index.source_ptr[s+1]-index.source_ptr[s]
        copyto!(rows,offset+1,index.source_rows,index.source_ptr[s],count);offset+=count
    end
    source=Int32[smap[index.source[r]] for r in rows];target=Int32[tmap[index.target[r]] for r in rows]
    source_ptr,source_rows=group_rows(source,length(sources));target_ptr,target_rows=group_rows(target,length(targets))
    local_index=(;source,target,source_ptr,source_rows,target_ptr,target_rows)
    local_meta=(;ids=meta.ids[sources],population=meta.population[sources],codes=meta.codes[sources],
        targets=meta.targets[targets],xyz=meta.xyz[:,sources],
        labels=Dict(smap[s]=>name for (s,name) in meta.labels if smap[s]>0))
    w=weight[rows]
    sort_groups!(target_rows,target_ptr,r->(@inbounds w[r]*local_meta.population[source[r]]))
    return (;meta=local_meta,index=local_index,weight=w,original_rows=rows)
end

function keep_groups!(keep,rows,ptr,score;top=0,retained=0.)
    top>=0 && 0<=retained<=1 || error("invalid selection limits")
    Threads.@threads for i in 1:length(ptr)-1
        first,last=ptr[i],ptr[i+1]-1
        total=retained>0 ? sum(score(rows[k]) for k in first:last) : 0.
        cumulative=0.
        for (rank,k) in enumerate(first:last)
            rank>top && cumulative>=retained*total && break
            r=rows[k];keep[r]=true;cumulative+=score(r)
        end
    end
    return keep
end

function select_rows(data;source_top=1,target_top=1,source_retained=0.,target_retained=0.)
    (;index,weight,meta)=data
    # Byte masks avoid concurrent read/modify/write operations on packed bits.
    keep=zeros(Bool,length(weight))
    keep_groups!(keep,index.source_rows,index.source_ptr,r->(@inbounds weight[r]);top=source_top,retained=source_retained)
    keep_groups!(keep,index.target_rows,index.target_ptr,r->(@inbounds weight[r]*meta.population[index.source[r]]);top=target_top,retained=target_retained)
    return Int32.(findall(keep))
end

function reference_stats(data)
    (;index,weight,meta)=data
    ns,nt=length(meta.ids),length(meta.targets)
    source_sum=zeros(ns);source_xy=zeros(2,ns);target_mass=zeros(nt);target_xyz=zeros(3,nt)
    for r in eachindex(weight)
        s,t=index.source[r],index.target[r];w=weight[r];mass=w*meta.population[s]
        source_sum[s]+=w
        source_xy[1,s]+=w*meta.targets[t][1];source_xy[2,s]+=w*meta.targets[t][2]
        target_mass[t]+=mass
        for k in 1:3
            target_xyz[k,t]+=mass*meta.xyz[k,s]
        end
    end
    source_xy./=transpose(source_sum);target_xyz./=transpose(target_mass)
    return (;source_sum,source_xy,target_mass,target_xyz)
end

function evaluate(data,rows,reference;weights=nothing)
    isnothing(weights) || (length(weights)==length(rows) && all(w->isfinite(w)&&w>0,weights)) || error("invalid reduced weights")
    (;index,weight,meta)=data
    ns,nt=length(meta.ids),length(meta.targets)
    retained=zeros(ns);target_retained=zeros(nt)
    for r in rows
        s,t=index.source[r],index.target[r]
        retained[s]+=weight[r];target_retained[t]+=weight[r]*meta.population[s]
    end
    all(>(0),retained) && all(>(0),target_retained) || error("selection lost coverage")
    source_xy=zeros(2,ns);source_sum=zeros(ns);target_mass=zeros(nt);target_xyz=zeros(3,nt)
    for (position,r) in enumerate(rows)
        s,t=index.source[r],index.target[r]
        w=isnothing(weights) ? weight[r]/retained[s] : weights[position]
        mass=w*meta.population[s];source_sum[s]+=w
        source_xy[1,s]+=w*meta.targets[t][1];source_xy[2,s]+=w*meta.targets[t][2]
        target_mass[t]+=mass
        for k in 1:3
            target_xyz[k,t]+=mass*meta.xyz[k,s]
        end
    end
    source_xy./=transpose(source_sum);target_xyz./=transpose(target_mass)
    tv=1 .- target_retained./reference.target_mass
    for (position,r) in enumerate(rows)
        s,t=index.source[r],index.target[r];mass=weight[r]*meta.population[s]
        newweight=isnothing(weights) ? weight[r]/retained[s] : weights[position]
        tv[t]+=abs(newweight*meta.population[s]/target_mass[t]-mass/reference.target_mass[t])
    end
    tv./=2
    forward=vec(sqrt.(sum(abs2,source_xy.-reference.source_xy;dims=1)))
    inverse=6371 .* vec(sqrt.(sum(abs2,target_xyz.-reference.target_xyz;dims=1)))
    mass_error=abs.(target_mass./reference.target_mass.-1)
    q(v,p)=quantile(v,p)
    return (;rows=length(rows),estimated_mb=30.125length(rows)/1e6,source_sum_error=maximum(abs.(source_sum.-1)),
        population_retained=sum(retained.*meta.population)/sum(meta.population),
        source_retained_p01=q(retained,.01),source_retained_p50=q(retained,.5),
        forward_p50=q(forward,.5),forward_p99=q(forward,.99),forward_max=maximum(forward),
        inverse_km_p50=q(inverse,.5),inverse_km_p99=q(inverse,.99),inverse_km_max=maximum(inverse),
        target_mass_error_p50=q(mass_error,.5),target_mass_error_p99=q(mass_error,.99),target_mass_error_max=maximum(mass_error),
        target_tv_p50=q(tv,.5),target_tv_p99=q(tv,.99),target_tv_max=maximum(tv))
end
end
