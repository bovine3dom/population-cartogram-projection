module ContinuityDiagnostics
using LinearAlgebra, Statistics, DataFrames, CSV

function source_separation_bound(a,b;chunk=256)
    largest=-1.0
    for first in 1:chunk:size(a.xyz,2)
        indices=first:min(first+chunk-1,size(a.xyz,2))
        largest=max(largest,maximum(transpose(a.xyz[:,indices])*b.xyz))
    end
    return 6371sqrt(max(0.,2-2largest))
end

function capacity_rms_bounds(countries,edges;relative_tolerance=.001)
    0<=relative_tolerance<1 || error("invalid target mass tolerance")
    rows=NamedTuple[]
    pairs=sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k!=l]))
    for (k,l) in pairs
        cross=filter(e->minmax(e[1],e[3])==(k,l),edges)
        distances2=6371^2 .* max.(0.,2 .- 2 .* (transpose(countries[k].xyz)*countries[l].xyz))
        maximum2=maximum(distances2)
        for (side,other,d) in ((k,l,vec(minimum(distances2;dims=2))),
                              (l,k,vec(minimum(distances2;dims=1))))
            c=countries[side]
            degree=Dict{Int,Int}()
            for e in cross
                j=e[1]==side ? e[2] : e[4]
                degree[j]=get(degree,j,0)+1
            end
            exposure(j)=degree[j]/((1+relative_tolerance)*c.b[j])
            targets=sort!(collect(keys(degree));by=exposure,rev=true)
            order=sortperm(d)
            mass=cumsum(c.a[order])
            costs=cumsum(c.a[order].*d[order])
            function prefix(amount)
                amount=clamp(amount,0.,last(mass))
                i=searchsortedfirst(mass,amount)
                return (i==1 ? 0. : costs[i-1])+(amount-(i==1 ? 0. : mass[i-1]))*d[order[i]]
            end
            filled=cost=0.0
            for j in targets
                next=filled+(1-relative_tolerance)*c.b[j]
                cost+=exposure(j)*(prefix(next)-prefix(filled))
                filled=next
            end
            n=length(cross)
            position=1+.9*(n-1)
            rank=floor(Int,position)
            fraction=position-rank
            maximum_exposure=maximum(degree[j]/((1-relative_tolerance)*c.b[j]) for j in targets)
            order_bound(r)=max(sqrt(prefix(r/maximum_exposure)/(r/maximum_exposure)),
                               sqrt(max(0.,(cost-(n-r)*maximum2)/r)))
            push!(rows,(;country=c.code,neighbour=countries[other].code,source_count=length(c.a),
                target_count=length(c.b),border_targets=length(targets),border_edges=n,
                population_fraction=sum(c.b[targets]),relative_tolerance,
                all_edge_rms_lower_bound_km=sqrt(cost/n),
                p90_rms_lower_bound_km=(1-fraction)*order_bound(rank)+fraction*order_bound(min(rank+1,n))))
        end
    end
    return DataFrame(rows)
end

# Lower bounds on expected physical separation, not on centroid separation.
function nearest_supply(countries, edges)
    pairs=sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k!=l]))
    rows=NamedTuple[]
    for (k,l) in pairs
        cross=filter(e -> minmax(e[1],e[3])==(k,l),edges)
        distances=6371 .* acos.(clamp.(transpose(countries[k].xyz)*countries[l].xyz,-1,1))
        for (side,other,d) in ((k,l,vec(minimum(distances;dims=2))),
                              (l,k,vec(minimum(distances;dims=1))))
            targets=Set(e[1]==side ? e[2] : e[4] for e in cross)
            c=countries[side]
            fraction=sum(c.b[collect(targets)])
            remaining=fraction
            cost=0.0
            radius=0.0
            for i in sortperm(d)
                used=min(c.a[i],remaining)
                cost+=used*d[i]
                remaining-=used
                radius=d[i]
                remaining<=1e-12 && break
            end
            push!(rows,(;country=c.code,neighbour=countries[other].code,
                        border_targets=length(targets),population_fraction=fraction,
                        mean_nearest_lower_bound_km=cost/fraction,supply_radius_km=radius))
        end
    end
    return DataFrame(rows)
end

function orientations(countries, plans)
    rows=NamedTuple[]
    for (c,p) in zip(countries,plans)
        q=c.xyz*p
        q ./= sqrt.(sum(abs2,q;dims=1))
        lookup=Dict((r.x,r.y)=>i for (i,r) in enumerate(eachrow(c.target)))
        step=2
        positive=negative=flat=0
        positive_area=negative_area=maximum_positive_area=0.0
        for ((x,y),i) in lookup
            all(haskey(lookup,k) for k in ((x+step,y),(x,y+step),(x+step,y+step))) || continue
            right,down,diagonal=[lookup[k] for k in ((x+step,y),(x,y+step),(x+step,y+step))]
            for (a,b,d) in ((i,right,down),(diagonal,down,right))
                area=6371^2*dot(q[:,a],cross(q[:,b]-q[:,a],q[:,d]-q[:,a]))/2
                if area>1
                    positive+=1
                    positive_area+=area
                    maximum_positive_area=max(maximum_positive_area,area)
                elseif area < -1
                    negative+=1
                    negative_area-=area
                else
                    flat+=1
                end
            end
        end
        push!(rows,(;country=c.code,positive,negative,flat,positive_area_km2=positive_area,
                    negative_area_km2=negative_area,maximum_positive_area_km2=maximum_positive_area))
    end
    return DataFrame(rows)
end

end

if abspath(PROGRAM_FILE)==@__FILE__
    using Serialization
    include("experiment.jl")
    length(ARGS)==2 || error("usage: diagnostics.jl SWEEP_DIRECTORY TRIAL_DIRECTORY")
    countries=deserialize(joinpath(ARGS[1],"countries.jls"))
    edges=ContinuityExperiment.graph(countries;borders=Set([(24,180),(24,894),(180,894)]))
    for name in ("baseline","candidate")
        plans=deserialize(joinpath(ARGS[2],"$name.jls"))
        ContinuityDiagnostics.CSV.write(joinpath(ARGS[2],"$name-orientation.csv"),
            ContinuityDiagnostics.orientations(countries,plans))
    end
    ContinuityDiagnostics.CSV.write(joinpath(ARGS[1],"supply-bounds.csv"),
        ContinuityDiagnostics.nearest_supply(countries,edges))
end
