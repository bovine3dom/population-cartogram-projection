module MobileQuality
using H3, Statistics, LinearAlgebra

function probe_fields(meta)
    density=meta.population./H3.API.cellAreaKm2.(meta.ids)
    names=["population_density","log1p_density"]
    fields=[density,log1p.(density)]
    for (name,lat,lon) in [("London",51.5,-.1),("Delhi",28.6,77.2),("Tokyo",35.7,139.7),
                           ("Nairobi",-1.3,36.8),("New_York",40.7,-74.)]
        lat,lon=deg2rad(lat),deg2rad(lon)
        origin=[cos(lat)*cos(lon),cos(lat)*sin(lon),sin(lat)]
        push!(names,"distance_km_"*name)
        push!(fields,6371 .* acos.(clamp.(vec(transpose(origin)*meta.xyz),-1.,1.)))
    end
    push!(names,"northern_hemisphere");push!(fields,Float64.(meta.xyz[3,:].>0))
    # Deterministic discontinuous and missing-data probes are not real datasets.
    noise=Float64[Float64(((id⊻(id>>23))*UInt64(0x9e3779b97f4a7c15))>>11)/2.0^53 for id in meta.ids]
    push!(names,"synthetic_noise");push!(fields,noise)
    push!(names,"half_missing_log_density");push!(fields,ifelse.(noise.>.5,log1p.(density),NaN))
    return names,permutedims(reduce(hcat,fields))
end

function target_values(data,rows,weights,fields)
    nf,ns=size(fields);ns==length(data.meta.ids) || error("field length mismatch")
    values=zeros(nf,length(data.meta.targets));mass=zero(values)
    for (position,r) in enumerate(rows)
        s,t=data.index.source[r],data.index.target[r]
        m=weights[position]*data.meta.population[s]
        for k in 1:nf
            v=fields[k,s]
            if isfinite(v)
                values[k,t]+=m*v;mass[k,t]+=m
            end
        end
    end
    return values./mass,mass
end

function compare_fields(data,rows,weights,names,fields)
    original,original_mass=target_values(data,eachindex(data.weight),data.weight,fields)
    candidate,candidate_mass=target_values(data,rows,weights,fields)
    return compare_values(original,original_mass,candidate,candidate_mass,names,fields)
end

function compare_values(original,original_mass,candidate,candidate_mass,names,fields)
    output=NamedTuple[]
    for k in eachindex(names)
        present=vec(original_mass[k,:].>0);both=present .& vec(candidate_mass[k,:].>0)
        error=abs.(candidate[k,both].-original[k,both])
        vals=filter(isfinite,fields[k,:]);span=isempty(vals) ? 0. : maximum(vals)-minimum(vals)
        q(p)=isempty(error) ? missing : quantile(error,p)
        push!(output,(;field=names[k],targets=count(present),lost=count(present .& .!both),
            absolute_p50=q(.5),absolute_p99=q(.99),absolute_max=q(1.),
            range_normalized_p99=span>0 ? q(.99)/span : q(1.)))
    end
    return output
end
end
