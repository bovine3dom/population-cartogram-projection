# Included inside ContinuityExperiment. All persistent storage is O((n+m)*depth).
struct GeometryCost <: AbstractMatrix{Float64}
    problem::PCP.MatrixFreeProblem
end
Base.size(c::GeometryCost)=(length(c.problem.source_x_hi),length(c.problem.target_x_hi))
Base.getindex(c::GeometryCost,i::Int,j::Int)=Float64(PCP._cost(c.problem,i,j))

mutable struct CompactPlan{D} <: AbstractMatrix{Float64}
    data::D
    problems::Vector{PCP.MatrixFreeProblem}
    stats::Any
end
Base.size(p::CompactPlan)=(size(p.data.u,1),size(p.data.v,1))
Base.getindex(p::CompactPlan,i::Int,j::Int)=exp(logentry(p.data,i,j))
function Base.sum(p::CompactPlan;dims=:)
    isnothing(p.stats) && error("plan statistics are not ready")
    dims==1 && return reshape(p.stats.target,1,:)
    dims==2 && return reshape(p.stats.source,:,1)
    dims==(:) && return sum(p.stats.source)
    error("unsupported compact sum dimensions")
end
means(c,p::CompactPlan)=p.stats.moment./transpose(p.stats.target)
transport_score(c,p::CompactPlan,eta,cache)=p.stats.base+eta*p.stats.entropy
valid_plan(p)=all(x->isfinite(x)&&x>=0,p)
valid_plan(p::CompactPlan)=!isnothing(p.stats) &&
    all(x->isfinite(x)&&x>0,p.stats.source) && all(x->isfinite(x)&&x>0,p.stats.target) &&
    all(isfinite,p.data.u) && all(isfinite,p.data.v) && all(isfinite,p.data.force)

@inline function logadd(a,b)
    a==-Inf && return b
    b==-Inf && return a
    hi=max(a,b)
    return hi+log1p(exp(-abs(a-b)))
end

function geometry_pack(problems)
    fields=(:source_x_hi,:source_x_lo,:source_y_hi,:source_y_lo,
            :target_x_hi,:target_x_lo,:target_y_hi,:target_y_lo)
    arrays=map(name->hcat([getproperty(p,name) for p in problems]...),fields)
    return (;source=(arrays[1:4]...,),target=(arrays[5:8]...,),scale=getproperty.(problems,:inverse_distance_scale))
end
@inline function geometry_entry(g,i,j,k)
    s,t=g.source,g.target
    return PCP._matrix_free_cost(s[1][i,k],s[2][i,k],s[3][i,k],s[4][i,k],
                                 t[1][j,k],t[2][j,k],t[3][j,k],t[4][j,k],g.scale[k])
end
@inline function logentry(h,i,j)
    value=oftype(h.u[1,1],-Inf)
    last_id=Int32(0);base=0.0f0
    for k in eachindex(h.inverse_eta)
        if h.base_id[k]!=last_id
            base=geometry_entry(h.geometry,i,j,h.base_id[k])
            last_id=h.base_id[k]
        end
        force=h.geo[1,i]*h.force[1,j,k]+h.geo[2,i]*h.force[2,j,k]+h.geo[3,i]*h.force[3,j,k]
        candidate=h.u[i,k]+h.v[j,k]-(base+force)*h.inverse_eta[k]
        if h.rho[k]>0
            candidate+=h.rho[k]*max(value,oftype(value,log(floatmin(Float64))))
        end
        value=logadd(h.keep[k]+value,h.take[k]+candidate)
    end
    return value
end

function empty_history(c)
    n,m=length(c.a),length(c.b)
    return (;geometry=geometry_pack([c.problem]),geo=c.xyz.-mean(c.xyz;dims=2),
        u=zeros(n,0),v=zeros(m,0),force=zeros(3,m,0),inverse_eta=Float64[],rho=Float64[],
        keep=Float64[],take=Float64[],base_id=Int32[])
end

function append_plan(c,prior,force,eta,proximal,alpha,beta)
    h=isnothing(prior) ? empty_history(c) : prior.data
    problems=isnothing(prior) ? [c.problem] : copy(prior.problems)
    index=findfirst(p->p===c.problem,problems)
    if isnothing(index)
        push!(problems,c.problem);index=length(problems)
    end
    geometry=length(problems)==length(h.geometry.scale) ? h.geometry : geometry_pack(problems)
    data=merge(h,(;geometry,u=hcat(h.u,alpha./eta),v=hcat(h.v,beta./eta),
        force=cat(h.force,reshape(force,3,length(c.b),1);dims=3),
        inverse_eta=vcat(h.inverse_eta,1/eta),rho=vcat(h.rho,proximal/eta),
        keep=vcat(h.keep,-Inf),take=vcat(h.take,0.),base_id=vcat(h.base_id,Int32(index))))
    return CompactPlan(data,problems,nothing)
end

function logblock(p,rows)
    result=Matrix{Float64}(undef,length(rows),size(p,2))
    Threads.@threads for j in axes(result,2)
        @inbounds for (k,i) in enumerate(rows)
            result[k,j]=logentry(p.data,i,j)
        end
    end
    return result
end

function compact_stats!(p,c;normalize=false,block_pairs=1_000_000)
    normalize && !(last(p.data.keep)==-Inf && last(p.data.take)==0) && error("normalize the unmixed candidate first")
    n,m=size(p)
    block=max(1,fld(block_pairs,m))
    target=zeros(m);source=zeros(n);moment=zeros(3,m);base=entropy=0.
    for firstrow in 1:block:n
        rows=firstrow:min(n,firstrow+block-1)
        logs=logblock(p,rows)
        if normalize
            maximums=maximum(logs;dims=2)
            weights=exp.(logs.-maximums)
            totals=sum(weights;dims=2)
            shifts=log.(c.a[rows]).-vec(maximums).-log.(vec(totals))
            p.data.u[rows,end].+=shifts
            logs.+=shifts
            weights.*=c.a[rows]./vec(totals)
        else
            weights=exp.(logs)
        end
        source[rows]=vec(sum(weights;dims=2))
        target.+=vec(sum(weights;dims=1))
        mul!(moment,view(c.xyz,:,rows),weights,1.,1.)
        @inbounds for j in 1:m,(k,i) in enumerate(rows)
            w=weights[k,j]
            base+=c.cost[i,j]*w
            w>0 && (entropy+=w*(logs[k,j]-1))
        end
    end
    p.stats=(;source,target,moment,base,entropy)
    return p
end

mix_plans(old,new,damping)=(1-damping).*old.+damping.*new
function mix_plans(old::CompactPlan,new::CompactPlan,damping)
    0<damping<=1 || error("invalid damping")
    depth=length(old.data.keep)
    length(new.data.keep)==depth+1 || error("candidate is not a direct update")
    view(new.data.u,:,1:depth)==old.data.u && view(new.data.v,:,1:depth)==old.data.v &&
        view(new.data.force,:,:,1:depth)==old.data.force && new.data.keep[1:depth]==old.data.keep &&
        new.data.take[1:depth]==old.data.take || error("candidate has a different parent")
    # Only the new last stage changes; previous arrays remain immutable.
    keep=copy(new.data.keep);take=copy(new.data.take)
    keep[end]=log1p(-damping);take[end]=log(damping)
    p=CompactPlan(merge(new.data,(;keep,take)),new.problems,nothing)
    entropy=0.
    block=max(1,fld(1_000_000,size(p,2)))
    for firstrow in 1:block:size(p,1)
        logs=logblock(p,firstrow:min(size(p,1),firstrow+block-1))
        entropy+=sum(x->isfinite(x) ? exp(x)*(x-1) : 0.,logs)
    end
    a,b=old.stats,new.stats
    blend(x,y)=(1-damping).*x.+damping.*y
    p.stats=(source=blend(a.source,b.source),target=blend(a.target,b.target),
        moment=blend(a.moment,b.moment),base=blend(a.base,b.base),entropy=entropy)
    return p
end

# Named tuples are adapted recursively by all supported KA backends.
function compact_device(backend,x::AbstractArray)
    y=eltype(x)<:AbstractFloat ? Float32.(x) : x
    return PCP._copy_to_backend(backend,y)
end
compact_device(backend,x::Union{NamedTuple,Tuple})=map(v->compact_device(backend,v),x)
compact_device(backend,x)=x

@inline function pair_cost(c::NamedTuple{(:compact_prior,:geometry,:geo,:force,:proximal,:offset)},i,j)
    base=geometry_entry(c.geometry,i,j,1)
    value=base+c.geo[1,i]*c.force[1,j]+c.geo[2,i]*c.force[2,j]+c.geo[3,i]*c.force[3,j]
    if c.proximal>0
        value-=c.proximal*max(logentry(c.compact_prior,i,j),oftype(value,log(floatmin(Float64))))
    end
    return (value-c.offset[1][i])-c.offset[2][j]
end

@kernel function compact_minimum!(out,cost,n,output_offset,::Val{ROWS}) where ROWS
    lane=@index(Local,Linear)
    group=@index(Group,Linear)
    j=output_offset+group
    minima=@localmem Float32 (32,)
    value=Inf32
    for i in lane:32:n
        value=min(value,ROWS ? pair_cost(cost,j,i) : pair_cost(cost,i,j))
    end
    minima[lane]=value
    @synchronize
    for offset in (16,8,4,2,1)
        if lane<=offset
            minima[lane]=min(minima[lane],minima[lane+offset])
        end
        @synchronize
    end
    group=@index(Group,Linear)
    if lane==1
        out[output_offset+group]=minima[1]
    end
end

# Online log-sum-exp evaluates the implicit history once, not twice, per pair.
@kernel function compact_reduce!(out,cost,dual,mass,eta,n,output_offset,::Val{ROWS}) where ROWS
    lane=@index(Local,Linear)
    group=@index(Group,Linear)
    j=output_offset+group
    maxima=@localmem Float32 (32,)
    totals=@localmem Float32 (32,)
    high=-Inf32;total=0.0f0
    for i in lane:32:n
        value=dual[i]-(ROWS ? pair_cost(cost,j,i) : pair_cost(cost,i,j))
        if total==0
            high=value;total=1.0f0
        elseif value<=high
            total+=exp((value-high)/eta)
        else
            total=total*exp((high-value)/eta)+1.0f0;high=value
        end
    end
    maxima[lane]=high;totals[lane]=total
    @synchronize
    for offset in (16,8,4,2,1)
        if lane<=offset
            right=totals[lane+offset]
            if right>0
                left=totals[lane]
                a,b=maxima[lane],maxima[lane+offset]
                if left==0
                    maxima[lane]=b;totals[lane]=right
                elseif b<=a
                    totals[lane]=left+right*exp((b-a)/eta)
                else
                    maxima[lane]=b;totals[lane]=left*exp((a-b)/eta)+right
                end
            end
        end
        @synchronize
    end
    group=@index(Group,Linear)
    if lane==1
        out[output_offset+group]=eta*log(mass[output_offset+group])-maxima[1]-eta*log(totals[1])
    end
end

@kernel function compact_materialize!(out,cost,offset)
    i,j=@index(Global,NTuple)
    out[i,j+offset]=pair_cost(cost,i,j+offset)
end

function compact_launches(f,backend,outputs,block)
    for (launch,offset) in enumerate(0:block:outputs-1)
        f(offset,min(block,outputs-offset))
        launch%8==0 && KA.synchronize(backend)
    end
    KA.synchronize(backend)
end

function compact_sinkhorn(c,force,prior,backend;eta=.002,proximal=0.,tolerance=1e-4,
                          maxiters=10000,initial_beta=nothing,accelerate=true,block_pairs=1_000_000,
                          cache_bytes=512*1024^2,max_pairs=8_000_000)
    isfinite(eta) && eta>0 && isfinite(proximal) && proximal>=0 || Base.error("invalid temperature or proximal weight")
    tolerance>0 && maxiters>0 && block_pairs>0 && cache_bytes>=0 && max_pairs>0 || Base.error("invalid solve limits")
    size(force)==(3,length(c.b)) && all(isfinite,force) || Base.error("invalid geographic forces")
    (!isnothing(prior) || proximal==0) || Base.error("proximal update requires a prior plan")
    isnothing(prior) || (size(prior)==size(c.cost) && valid_plan(prior)) || Base.error("invalid prior plan")
    eta=eta+proximal
    # Removing row and column terms leaves the balanced optimum unchanged.
    force=force.-mean(force;dims=2)
    host=(;compact_prior=isnothing(prior) ? empty_history(c) : prior.data,
        geometry=geometry_pack([c.problem]),geo=c.xyz.-mean(c.xyz;dims=2),force,
        proximal=Float32(proximal),offset=(zeros(Float32,length(c.a)),zeros(Float32,length(c.b))))
    device=compact_device(backend,host)
    row_device=KA.zeros(backend,Float32,length(c.a))
    offset_device=KA.zeros(backend,Float32,length(c.b))
    budget=max(1,div(max_pairs,1+length(host.compact_prior.rho)))
    minimum_kernel! = compact_minimum!(backend,32)
    function minimum!(out,cost,n,rows)
        block=max(1,div(budget,n))
        compact_launches(backend,length(out),block) do offset,count
            minimum_kernel!(out,cost,n,offset,rows;ndrange=32count)
        end
    end
    minimum!(row_device,device,length(c.b),Val(true))
    device=merge(device,(;offset=(row_device,device.offset[2])))
    minimum!(offset_device,device,length(c.a),Val(false))
    row_offset=PCP._copy_to_host!(backend,zeros(Float32,length(c.a)),row_device)
    offset=PCP._copy_to_host!(backend,zeros(Float32,length(c.b)),offset_device)
    device=merge(device,(;offset=(row_device,offset_device)))
    # Cache only the current country's cost, within an explicit device budget.
    cost_device=if length(c.a)*length(c.b)<=div(cache_bytes,sizeof(Float32))
        cached=KA.allocate(backend,Float32,(length(c.a),length(c.b)))
        block=max(1,div(budget,length(c.a)))
        materialize! = compact_materialize!(backend,(32,8))
        compact_launches(backend,length(c.b),block) do offset,count
            materialize!(cached,device,offset;ndrange=(length(c.a),count))
        end
        cached
    else
        device
    end
    da=PCP._copy_to_backend(backend,Float32.(c.a));db=PCP._copy_to_backend(backend,Float32.(c.b))
    alpha=KA.zeros(backend,Float32,length(c.a))
    beta=PCP._copy_to_backend(backend,isnothing(initial_beta) ? zeros(Float32,length(c.b)) : Float32.(initial_beta.-offset))
    probe=KA.zeros(backend,Float32,length(c.b))
    host_beta=zeros(Float32,length(c.b));host_probe=similar(host_beta)
    update_kernel! = compact_reduce!(backend,32)
    reduction_budget=cost_device isa AbstractMatrix ? max_pairs : budget
    function update!(out,dual,mass,n,rows)
        block=max(1,div(reduction_budget,n))
        compact_launches(backend,length(out),block) do offset,count
            update_kernel!(out,cost_device,dual,mass,Float32(eta),n,offset,rows;ndrange=32count)
        end
    end
    function residual!()
        update!(alpha,beta,da,length(c.b),Val(true))
        update!(probe,alpha,db,length(c.a),Val(false))
        PCP._copy_to_host!(backend,host_beta,beta);PCP._copy_to_host!(backend,host_probe,probe)
        ratios=exp.((Float64.(host_beta).-host_probe)./eta)
        return max(sum(c.b.*abs.(ratios.-1))/tolerance,maximum(abs.(ratios.-1))/.001)
    end
    outputs=Vector{Float64}[];residuals=Vector{Float64}[]
    previous=isnothing(initial_beta) ? zeros(length(c.b)) : Float64.(initial_beta.-offset)
    previous.-=mean(previous)
    error=Inf
    for iteration in 1:maxiters
        update!(alpha,beta,da,length(c.b),Val(true))
        update!(beta,alpha,db,length(c.a),Val(false))
        iteration%50==0 || continue
        error=residual!()
        if accelerate
            current=Float64.(host_beta);current.-=mean(current)
            push!(outputs,current);push!(residuals,current-previous)
            length(outputs)>5 && (popfirst!(outputs);popfirst!(residuals))
            proposal=anderson_candidate(outputs,residuals)
            if !isnothing(proposal)
                old=copy(host_beta)
                beta=PCP._copy_to_backend(backend,Float32.(proposal))
                candidate_error=residual!()
                if candidate_error<.9error
                    error=candidate_error
                else
                    beta=PCP._copy_to_backend(backend,old)
                    error=residual!()
                end
            end
            previous=Float64.(host_beta);previous.-=mean(previous)
        end
        if iteration%1000==0
            println("Compact inner iteration=$iteration scaled_device_residual=$error history=$(length(host.compact_prior.rho))");flush(stdout)
        end
        if error<=1.2
            a=Float64.(PCP._copy_to_host!(backend,zeros(Float32,length(c.a)),alpha)).+row_offset
            b=Float64.(host_beta).+offset
            plan=append_plan(c,prior,force,eta,proximal,a,b)
            compact_stats!(plan,c;normalize=true,block_pairs)
            actual=sum(abs.(plan.stats.target.-c.b))
            relative=maximum(abs.(plan.stats.target./c.b.-1))
            if actual<=tolerance && relative<=.001
                return (;plan,beta=b,iterations=iteration,refinement_iterations=0,marginal_error=actual)
            end
        end
    end
    Base.error("compact Sinkhorn did not converge; scaled GPU residual=$error")
end
