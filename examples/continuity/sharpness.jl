# Compare source distributions at the same retained mass, not only file row counts.
module ContinuitySharpness
using Statistics

function distribution(weights, xy; retained=(.995,.99999))
    length(weights)==length(xy)>0 || error("empty or mismatched distribution")
    all(q->0<q<=1,retained) || error("invalid retained fraction")
    merged=Dict{Tuple{Float64,Float64},Float64}()
    for (w,pos) in zip(weights,xy)
        isfinite(w) && w>=0 && all(isfinite,pos) || error("invalid distribution")
        w>0 || continue
        key=(Float64(pos[1]),Float64(pos[2]))
        merged[key]=get(merged,key,0.)+w
    end
    total=sum(values(merged));total>0 || error("zero source mass")
    probabilities=sort!(collect(values(merged))./total;rev=true)
    cumulative=cumsum(probabilities)
    counts=map(q->min(searchsortedfirst(cumulative,q),length(probabilities)),retained)
    mx=sum(w*pos[1] for (pos,w) in merged)/total
    my=sum(w*pos[2] for (pos,w) in merged)/total
    variance=sum(w*((pos[1]-mx)^2+(pos[2]-my)^2) for (pos,w) in merged)/total
    return (;mass=total,cells=length(probabilities),counts,
        effective_entropy=exp(-sum(p*log(p) for p in probabilities)),
        effective_simpson=inv(sum(abs2,probabilities)),top1=first(probabilities),
        spread=sqrt(max(0.,variance)))
end

function source_rows(data)
    (;meta,index,weight)=data
    target_mass=zeros(length(meta.targets))
    for r in eachindex(weight)
        target_mass[index.target[r]]+=weight[r]*meta.population[index.source[r]]
    end
    max_capacity=maximum(target_mass)
    uniform_capacity=sum(meta.population)/length(meta.targets)
    return map(eachindex(meta.ids)) do s
        rows=view(index.source_rows,index.source_ptr[s]:index.source_ptr[s+1]-1)
        stats=distribution(view(weight,rows),((meta.targets[index.target[r]][1],meta.targets[index.target[r]][2]) for r in rows))
        (;id=meta.ids[s],code=meta.codes[s],population=meta.population[s],
            quota=meta.population[s]/uniform_capacity,
            capacity_quota=meta.population[s]*stats.mass/max_capacity,
            source_mass=stats.mass,cells=stats.cells,n995=stats.counts[1],n99999=stats.counts[2],
            effective_entropy=stats.effective_entropy,effective_simpson=stats.effective_simpson,
            top1=stats.top1,spread=stats.spread)
    end
end

# readblock returns joint masses for a bounded set of complete source rows.
function plan_rows(c,p,readblock;block_pairs=1_000_000)
    block_pairs>0 || error("invalid block size")
    n,m=size(p);n==length(c.a) && m==length(c.b) || error("plan shape differs")
    xy=collect(zip(c.target.x,c.target.y));rows=NamedTuple[]
    block=max(1,fld(block_pairs,m))
    for first in 1:block:n
        selected=first:min(first+block-1,n)
        mass=readblock(p,selected)
        size(mass)==(length(selected),m) || error("wrong block shape")
        for (i,s) in enumerate(selected)
            stats=distribution(view(mass,i,:),xy)
            push!(rows,(;id=c.source.id[s],code=c.code,population=c.source.value[s],
                quota=c.a[s]*m,capacity_quota=stats.mass/maximum(c.b),
                source_mass=stats.mass/c.a[s],cells=stats.cells,
                n995=stats.counts[1],n99999=stats.counts[2],
                effective_entropy=stats.effective_entropy,effective_simpson=stats.effective_simpson,
                top1=stats.top1,spread=stats.spread))
        end
    end
    return rows
end

function summarize(rows,targets)
    n=length(rows);population=sum(r.population for r in rows)
    support=sum(r.cells for r in rows);support995=sum(r.n995 for r in rows)
    return (;sources=n,targets,connections=support,connections995=support995,
        connections99999=sum(r.n99999 for r in rows),ratio=support/n,ratio995=support995/n,
        old_budget=2(n+targets),budget_ratio995=support995/(2(n+targets)),
        n995_p50=quantile([r.n995 for r in rows],.5),n995_p90=quantile([r.n995 for r in rows],.9),
        n995_p99=quantile([r.n995 for r in rows],.99),n995_max=maximum(r.n995 for r in rows),
        effective_mean=mean(r.effective_simpson for r in rows),
        entropy_mean=mean(r.effective_entropy for r in rows),
        spread_mean=mean(r.spread for r in rows),spread_p99=quantile([r.spread for r in rows],.99),
        population_weighted_spread=sum(r.population*r.spread for r in rows)/population,
        top1_mean=mean(r.top1 for r in rows))
end
end
