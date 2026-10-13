module MobileAudit
using Arrow, H3, Statistics, TOML
include("../mobile_export.jl")
const ME=MobileExport

function stats(table,meta)
    ns,nt=length(meta.ids),length(meta.targets)
    xy=unique([(x,y) for (x,y,_) in meta.targets]);xy_index=Dict(k=>i for (i,k) in enumerate(xy))
    physical=[xy_index[(x,y)] for (x,y,_) in meta.targets]
    source_sum=zeros(ns);source_xy=zeros(2,ns);mass=zeros(nt);xyz=zeros(3,nt);density=zeros(nt)
    source_density=meta.population./H3.API.cellAreaKm2.(meta.ids)
    physical_mass=zeros(length(xy));mean_sum=zeros(length(xy));counts=zeros(Int,nt);firstrow=fill(typemax(Int),nt)
    labels=Dict{UInt64,Tuple{String,Int,Int}}()
    for r in eachindex(table.weight)
        id=ME.cellid(table.index_lower[r],table.index_upper[r]);s=meta.source_index[id]
        x,y,code=Int(table.x[r]),Int(table.y[r]),Int(table.code[r])
        t=meta.target_index[(x,y,code)];p=physical[t]
        table.population[r]==meta.population[s] && code==meta.codes[s] || error("source metadata changed at row $r")
        w=Float64(table.weight[r]);wm=Float64(table.weight_mean[r]);m=w*meta.population[s]
        isfinite(w) && w>0 && isfinite(wm) && wm>0 || error("invalid weight at row $r")
        source_sum[s]+=w;source_xy[1,s]+=w*x;source_xy[2,s]+=w*y
        mass[t]+=m;density[t]+=m*source_density[s]
        for k in 1:3
            xyz[k,t]+=m*meta.xyz[k,s]
        end
        physical_mass[p]+=m;mean_sum[p]+=wm;counts[t]+=1;firstrow[t]=min(firstrow[t],r)
        if !ismissing(table.label[r])
            haskey(labels,id) && error("duplicate city label")
            labels[id]=(String(table.label[r]),x,y)
        end
    end
    all(>(0),source_sum) && all(>(0),mass) || error("coverage changed")
    Dict(id=>v[1] for (id,v) in labels)==Dict(meta.ids[s]=>name for (s,name) in meta.labels) || error("city names changed")
    mean_error=0.
    for r in eachindex(table.weight)
        p=xy_index[(Int(table.x[r]),Int(table.y[r]))]
        expected=Float64(table.weight[r])*table.population[r]/physical_mass[p]
        mean_error=max(mean_error,abs(table.weight_mean[r]/expected-1))
    end
    owners=Dict{Tuple{Int,Int},Tuple{Int,Int,Int}}()
    for (t,(x,y,code)) in enumerate(meta.targets)
        key=(x,y);value=(-counts[t],firstrow[t],code)
        (!haskey(owners,key) || value<owners[key]) && (owners[key]=value)
    end
    return (;source_sum,source_xy=source_xy./transpose(source_sum),mass,xyz=xyz./transpose(mass),density=density./mass,
        labels,owners=Dict(k=>v[3] for (k,v) in owners),mean_error,mean_sum_error=maximum(abs.(mean_sum.-1)))
end

function audit(input,reference,candidate,density_file,report)
    original=Arrow.Table(input)
    meta=ME.metadata(original.index_lower,original.index_upper,original.x,original.y,
        original.population,original.code,original.label)
    table=Arrow.Table(candidate)
    for (name,type) in [(:x,Int16),(:y,Int16),(:code,UInt16),(:weight,Float32),(:weight_mean,Float32),
                        (:population,Float64),(:index_lower,UInt32),(:index_upper,UInt32)]
        eltype(getproperty(table,name))==type || error("wrong type for $name")
    end
    reduced=stats(table,meta);full=stats(Arrow.Table(reference),meta)
    reduced.labels==full.labels || error("city anchor changed")
    reduced.owners==full.owners || error("shared-cell country owner changed")
    forward=vec(sqrt.(sum(abs2,reduced.source_xy.-full.source_xy;dims=1)))
    inverse=6371 .* vec(sqrt.(sum(abs2,reduced.xyz.-full.xyz;dims=1)))
    mass_error=abs.(reduced.mass./full.mass.-1)
    density_error=abs.(reduced.density./full.density.-1)
    source_error=maximum(abs.(reduced.source_sum.-1))
    source_error<=1e-7 || error("source sum error $source_error")
    reduced.mean_error<=1e-7 && reduced.mean_sum_error<=1e-7 || error("target weight error")
    maximum(mass_error)<=2e-5 && maximum(forward)<=.002 && maximum(inverse)<=.002 || error("projection error budget exceeded")
    maximum(density_error)<=.001 || error("density error budget exceeded")
    density=Arrow.Table(density_file);seen=Set{UInt64}()
    for r in eachindex(density.value)
        id=ME.cellid(density.index_lower[r],density.index_upper[r]);s=meta.source_index[id]
        id in seen && error("duplicate density cell");push!(seen,id)
        isfinite(density.value[r]) && density.value[r]>0 || error("invalid density")
        isapprox(density.value[r],meta.population[s]/H3.API.cellAreaKm2(id);rtol=1e-12) || error("density changed")
    end
    seen==Set(meta.ids) || error("density coverage changed")
    output=Dict("rows"=>length(table.weight),"sources"=>length(meta.ids),"targets"=>length(meta.targets),"labels"=>length(reduced.labels),
        "source_sum_error"=>source_error,"target_mean_sum_error"=>reduced.mean_sum_error,
        "physical_weight_relative_error"=>reduced.mean_error,"target_mass_relative_error_max"=>maximum(mass_error),
        "forward_error_max"=>maximum(forward),"geographic_error_km_max"=>maximum(inverse),
        "density_relative_error_max"=>maximum(density_error),"density_relative_error_p99"=>quantile(density_error,.99))
    open(io->TOML.print(io,output),report,"w")
    return output
end
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==5 || error("usage: audit.jl INPUT REFERENCE CANDIDATE DENSITY REPORT")
    MobileAudit.audit(ARGS...)
end
