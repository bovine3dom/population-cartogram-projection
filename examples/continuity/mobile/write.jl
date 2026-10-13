module MobileWriter
using Arrow, Serialization

# Retain only selected indexes before loading the next country cache.
function select_part(data,result)
    length(result.rows)==length(result.weights) || error("invalid result")
    anchors=Dict(data.index.source_rows[data.index.source_ptr[s]]=>name for (s,name) in data.meta.labels)
    labels=Dict(k=>anchors[r] for (k,r) in enumerate(result.rows) if haskey(anchors,r))
    length(labels)==length(anchors) || error("missing city anchor")
    return (;meta=data.meta,source=data.index.source[result.rows],target=data.index.target[result.rows],
        weights=result.weights,labels)
end

# Keep population in Float64. Shared target coordinates use one physical mass.
function columns(parts;owners=Dict(),counts=nothing)
    count=sum(length(p.weights) for p in parts)
    x=Vector{Int16}(undef,count);y=similar(x);code=Vector{UInt16}(undef,count)
    weight=Vector{Float32}(undef,count);weight_mean=similar(weight)
    population=Vector{Float64}(undef,count)
    index_lower=Vector{UInt32}(undef,count);index_upper=similar(index_lower)
    label=Vector{Union{Missing,String}}(missing,count)
    mass=Dict{Tuple{Int16,Int16},Float64}();offset=0
    for (;meta,source,target,weights,labels) in parts
        sums=zeros(length(meta.ids))
        for k in eachindex(weights)
            sums[source[k]]+=weights[k]
        end
        all(s->isfinite(s)&&s>0,sums) || error("missing or invalid source mass")
        for k in eachindex(weights)
            i=offset+k;s=source[k];t=target[k]
            tx,ty,c=meta.targets[t];id=meta.ids[s]
            x[i]=tx;y[i]=ty;code[i]=c
            weight[i]=weights[k]/sums[s]
            isfinite(weight[i]) && weight[i]>=0 || error("invalid Float32 weight")
            population[i]=meta.population[s]
            index_lower[i]=id&0xffffffff;index_upper[i]=id>>32
            haskey(labels,k) && (label[i]=labels[k])
        end
        offset+=length(weights)
    end
    for i in eachindex(weight)
        key=(x[i],y[i]);mass[key]=get(mass,key,0.)+Float64(weight[i])*population[i]
    end
    all(>(0),values(mass)) || error("target mass cannot be represented in Float32")
    # Remove roundoff tails only when both source and target fractions are tiny.
    # Do this before the ownership guard, and never remove a labelled row.
    dropped=findall(i->ismissing(label[i]) && weight[i]<1e-20 &&
        Float64(weight[i])*population[i]/mass[(x[i],y[i])]<1e-20,eachindex(weight))
    for col in (x,y,code,weight,population,index_lower,index_upper,label,weight_mean)
        deleteat!(col,dropped)
    end
    all(>(0),weight) || error("a required weight cannot be represented in Float32")
    empty!(mass)
    # The consumer chooses country ownership by row count, not transported mass.
    # Split an existing row if sparsification would change a shared cell's owner.
    for ((tx,ty),owner) in owners
        country_counts=Dict{UInt16,Int}();best=0
        for i in eachindex(weight)
            x[i]==tx && y[i]==ty || continue
            country_counts[code[i]]=get(country_counts,code[i],0)+1
            code[i]==owner && (best==0 || weight[i]>weight[best]) && (best=i)
        end
        best>0 || error("missing shared-cell owner")
        extra=max(0,maximum((n for (c,n) in country_counts if c!=owner);init=0)+1-country_counts[UInt16(owner)])
        weight[best]/=extra+1
        for _ in 1:extra
            for col in (x,y,code,weight,population,index_lower,index_upper)
                push!(col,col[best])
            end
            push!(label,missing);push!(weight_mean,0)
        end
    end
    for i in eachindex(weight)
        key=(x[i],y[i]);mass[key]=get(mass,key,0.)+Float64(weight[i])*population[i]
    end
    for i in eachindex(weight)
        weight_mean[i]=Float64(weight[i])*population[i]/mass[(x[i],y[i])]
        isfinite(weight_mean[i]) && weight_mean[i]>0 || error("invalid Float32 target weight")
    end
    isnothing(counts) || (counts[]=(;dropped_rows=length(dropped),ownership_rows=length(weight)+length(dropped)-count))
    return (;x,y,weight,population,code,label,weight_mean,index_lower,index_upper)
end

function write_density(path,input)
    ispath(path) && error("refusing to replace $path")
    table=Arrow.Table(input)
    Set(propertynames(table))==Set((:index_lower,:index_upper,:value)) || error("unexpected density columns")
    columns=(;index_lower=Arrow.DictEncode(table.index_lower),index_upper=table.index_upper,value=table.value)
    mkpath(dirname(path))
    Arrow.write(path*".pending",columns;ntasks=1)
    mv(path*".pending",path)
    return filesize(path)
end

function write_file(path,parts;owners=Dict(),dictionary=false)
    ispath(path) && error("refusing to replace $path")
    counts=Ref((;dropped_rows=0,ownership_rows=0))
    table=columns(parts;owners,counts)
    if dictionary
        table=merge(table,(;index_lower=Arrow.DictEncode(table.index_lower),
            population=Arrow.DictEncode(table.population),label=Arrow.DictEncode(table.label)))
    end
    mkpath(dirname(path))
    Arrow.write(path*".pending",table;ntasks=1)
    mv(path*".pending",path)
    return (;rows=length(table.weight),bytes=filesize(path),counts[]...)
end
end
