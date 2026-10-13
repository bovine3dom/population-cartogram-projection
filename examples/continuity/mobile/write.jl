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
function columns(parts)
    count=sum(length(p.weights) for p in parts)
    x=Vector{Int16}(undef,count);y=similar(x);code=Vector{UInt16}(undef,count)
    weight=Vector{Float32}(undef,count);weight_mean=similar(weight)
    population=Vector{Float64}(undef,count)
    index_lower=Vector{UInt32}(undef,count);index_upper=similar(index_lower)
    label=Vector{Union{Missing,String}}(missing,count)
    mass=Dict{Tuple{Int16,Int16},Float64}();offset=0
    for (;meta,source,target,weights,labels) in parts
        for k in eachindex(weights)
            i=offset+k;s=source[k];t=target[k]
            tx,ty,c=meta.targets[t];id=meta.ids[s]
            x[i]=tx;y[i]=ty;code[i]=c
            weight[i]=weights[k]
            isfinite(weight[i]) && weight[i]>0 || error("invalid Float32 weight")
            population[i]=meta.population[s]
            index_lower[i]=id&0xffffffff;index_upper[i]=id>>32
            key=(x[i],y[i]);mass[key]=get(mass,key,0.)+Float64(weight[i])*population[i]
            haskey(labels,k) && (label[i]=labels[k])
        end
        offset+=length(weights)
    end
    for i in eachindex(weight)
        weight_mean[i]=Float64(weight[i])*population[i]/mass[(x[i],y[i])]
        isfinite(weight_mean[i]) && weight_mean[i]>0 || error("invalid Float32 target weight")
    end
    return (;x,y,weight,population,code,label,weight_mean,index_lower,index_upper)
end

function write_file(path,parts)
    ispath(path) && error("refusing to replace $path")
    table=columns(parts)
    mkpath(dirname(path))
    Arrow.write(path*".pending",table;ntasks=1)
    mv(path*".pending",path)
    return (;rows=length(table.weight),bytes=filesize(path))
end
end
