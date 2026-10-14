# Include after experiment.jl. The fixed sparse graph is part of this model.
module SparseRefinement
using ..ContinuityExperiment
using KernelAbstractions: @kernel, @index, @localmem, @synchronize
using Statistics
const CE=ContinuityExperiment
const KA=CE.KA
const PCP=CE.PCP

function graph(n,m,source,target,cost;maxedges=20_000_000)
    max(n,m,length(cost)+1)<=typemax(Int32) || error("graph exceeds Int32 limits")
    length(cost)<=maxedges || error("graph exceeds edge budget")
    n>0 && m>0 && length(source)==length(target)==length(cost)>0 || error("invalid graph dimensions")
    all(i->1<=i<=n,source) && all(j->1<=j<=m,target) || error("invalid edge index")
    all(isfinite,cost) || error("invalid cost")
    order=sortperm(eachindex(cost);by=k->(source[k],target[k]))
    i=Int32.(source[order]);j=Int32.(target[order]);c=Float64.(cost[order])
    any(k->i[k]==i[k-1] && j[k]==j[k-1],2:length(i)) && error("duplicate graph edge")
    rc=zeros(Int32,n);cc=zeros(Int32,m)
    for (s,t) in zip(i,j);rc[s]+=1;cc[t]+=1;end
    all(>(0),rc) && all(>(0),cc) || error("empty graph row or column")
    rp=Int32[1;1 .+ cumsum(rc)];cp=Int32[1;1 .+ cumsum(cc)]
    perm=sortperm(j);shifted=copy(c);rowoffset=zeros(n);coloffset=fill(Inf,m)
    for s in 1:n
        r=rp[s]:rp[s+1]-1;rowoffset[s]=minimum(view(shifted,r));shifted[r].-=rowoffset[s]
    end
    for k in eachindex(c);coloffset[j[k]]=min(coloffset[j[k]],shifted[k]);end
    shifted.-=coloffset[j]
    return (;n,m,source=i,target=j,cost=c,shifted,rowoffset,coloffset,perm,
        rows=(ptr=rp,indices=j,max_count=maximum(rc)),columns=(ptr=cp,indices=i[perm],max_count=maximum(cc)))
end

@kernel function log_reduce!(out,layout,dual,mass,eta,offset)
    lane=@index(Local,Linear);group=@index(Group,Linear);row=offset+group
    maxima=@localmem Float32 (32,);totals=@localmem Float32 (32,)
    hi=-Inf32
    for e in (layout.ptr[row]+lane-1):32:(layout.ptr[row+1]-1)
        hi=max(hi,(dual[layout.indices[e]]-layout.values[e])/eta)
    end
    maxima[lane]=hi;@synchronize
    for stride in (16,8,4,2,1)
        if lane<=stride;maxima[lane]=max(maxima[lane],maxima[lane+stride]);end
        @synchronize
    end
    group=@index(Group,Linear);row=offset+group
    total=0.0f0
    for e in (layout.ptr[row]+lane-1):32:(layout.ptr[row+1]-1)
        total+=exp((dual[layout.indices[e]]-layout.values[e])/eta-maxima[1])
    end
    totals[lane]=total;@synchronize
    for stride in (16,8,4,2,1)
        if lane<=stride;totals[lane]+=totals[lane+stride];end
        @synchronize
    end
    group=@index(Group,Linear);row=offset+group
    if lane==1;out[row]=eta*(log(mass[row])-maxima[1]-log(totals[1]));end
end

@kernel function small_log_reduce!(out,layout,dual,mass,eta,offset,limit)
    index=@index(Global,Linear)
    row=offset+index
    if row<=limit
        hi=-Inf32
        for e in layout.ptr[row]:layout.ptr[row+1]-1
            hi=max(hi,(dual[layout.indices[e]]-layout.values[e])/eta)
        end
        total=0.0f0
        for e in layout.ptr[row]:layout.ptr[row+1]-1
            total+=exp((dual[layout.indices[e]]-layout.values[e])/eta-hi)
        end
        out[row]=eta*(log(mass[row])-hi-log(total))
    end
end

@kernel function small_scale_reduce!(out,layout,scale,mass,offset,limit)
    index=@index(Global,Linear)
    row=offset+index
    if row<=limit
        total=0.0f0
        for e in layout.ptr[row]:layout.ptr[row+1]-1
            total+=layout.values[e]*scale[layout.indices[e]]
        end
        out[row]=mass[row]/total
    end
end

function weights(g,a,beta,eta)
    w=similar(g.cost)
    for i in 1:g.n
        r=g.rows.ptr[i]:g.rows.ptr[i+1]-1
        @views w[r].=(beta[g.target[r]].-g.shifted[r])./eta
        hi=maximum(view(w,r));@views w[r].=exp.(w[r].-hi)
        @views w[r].*=a[i]/sum(w[r])
    end
    return w
end

function residual(g,w,a,b)
    row=zeros(g.n);column=zeros(g.m)
    for k in eachindex(w);row[g.source[k]]+=w[k];column[g.target[k]]+=w[k];end
    return (;l1=sum(abs.(column.-b)),relative=maximum(abs.(column./b.-1)),source=maximum(abs.(row./a.-1)))
end

function device_graph(g,w,backend)
    CE.compact_device(backend,(rows=merge(g.rows,(;values=Float32.(w))),
        columns=merge(g.columns,(;values=Float32.(w[g.perm])))))
end

function polish(g,w,a,b,backend;tolerance,maxrelative,maxiters=10000,deadline=Inf)
    device=device_graph(g,w,backend);commands=Ref(0)
    u=PCP._copy_to_backend(backend,ones(Float32,g.n));v=PCP._copy_to_backend(backend,ones(Float32,g.m))
    da=PCP._copy_to_backend(backend,Float32.(a));db=PCP._copy_to_backend(backend,Float32.(b))
    probe=similar(v);reduce! = CE.sparse_scale_reduce!(backend,32)
    small! = small_scale_reduce!(backend,256)
    function update!(out,layout,scale,mass)
        short=length(layout.values)<=16length(out)
        CE.compact_launches(backend,length(out),max(1,div(8_000_000,layout.max_count)),commands) do offset,count
            if short;small!(out,layout,scale,mass,offset,offset+count;ndrange=count)
            else;reduce!(out,layout,scale,mass,offset;ndrange=32count);end
        end
    end
    for iteration in 1:maxiters
        iteration%20==1 && time()>=deadline && return nothing
        update!(u,device.rows,v,da);update!(v,device.columns,u,db)
        iteration%20==0 || continue
        update!(u,device.rows,v,da);update!(probe,device.columns,u,db)
        hv=Float64.(Array(v));hp=Float64.(Array(probe))
        all(x->isfinite(x)&&x>0,hv) && all(x->isfinite(x)&&x>0,hp) || return nothing
        ratio=hv./hp
        sum(b.*abs.(ratio.-1))<=.8tolerance && maximum(abs.(ratio.-1))<=.8maxrelative || continue
        hu=Float64.(Array(u));all(x->isfinite(x)&&x>0,hu) || return nothing
        result=w.*hu[g.source].*hv[g.target]
        for i in 1:g.n
            r=g.rows.ptr[i]:g.rows.ptr[i+1]-1;@views result[r].*=a[i]/sum(result[r])
        end
        error=residual(g,result,a,b)
        error.l1<=tolerance && error.relative<=maxrelative && error.source<=1e-10 &&
            return (;weights=result,correction=log.(hv),iterations=iteration,error)
    end
    return nothing
end

function solve(g,a,b,backend;eta,initial_beta=nothing,tolerance=1e-6,maxrelative=1e-4,maxiters=10000,deadline=Inf)
    length(a)==g.n && length(b)==g.m && all(x->isfinite(x)&&x>0,a) && all(x->isfinite(x)&&x>0,b) || error("invalid masses")
    isapprox(sum(a),1.;atol=1e-12) && isapprox(sum(b),1.;atol=1e-12) || error("masses must sum to one")
    all(isfinite,(eta,tolerance,maxrelative)) && eta>0 && tolerance>0 && maxrelative>0 && maxiters>0 || error("invalid solve limits")
    time()<deadline || error("sparse refinement deadline reached")
    isnothing(initial_beta) || length(initial_beta)==g.m && all(isfinite,initial_beta) || error("invalid initial dual")
    device=device_graph(g,g.shifted,backend);commands=Ref(0)
    da=PCP._copy_to_backend(backend,Float32.(a));db=PCP._copy_to_backend(backend,Float32.(b))
    alpha=KA.zeros(backend,Float32,g.n);probe=KA.zeros(backend,Float32,g.m)
    beta=PCP._copy_to_backend(backend,isnothing(initial_beta) ? zeros(Float32,g.m) : Float32.(initial_beta.-g.coloffset))
    update_kernel! = log_reduce!(backend,32)
    small! = small_log_reduce!(backend,256)
    function update!(out,layout,dual,mass)
        short=length(layout.values)<=16length(out)
        CE.compact_launches(backend,length(out),max(1,div(8_000_000,layout.max_count)),commands) do offset,count
            if short;small!(out,layout,dual,mass,Float32(eta),offset,offset+count;ndrange=count)
            else;update_kernel!(out,layout,dual,mass,Float32(eta),offset;ndrange=32count);end
        end
    end
    function check!()
        update!(alpha,device.rows,beta,da);update!(probe,device.columns,alpha,db)
        current=Float64.(Array(beta));ratio=exp.((current.-Float64.(Array(probe)))./eta)
        return current,max(sum(b.*abs.(ratio.-1))/tolerance,maximum(abs.(ratio.-1))/maxrelative)
    end
    outputs=Vector{Float64}[];differences=Vector{Float64}[];previous=Float64.(Array(beta));previous.-=mean(previous)
    for iteration in 1:maxiters
        iteration%50==1 && time()>=deadline && error("sparse refinement deadline reached")
        update!(alpha,device.rows,beta,da);update!(beta,device.columns,alpha,db)
        iteration%50==0 || continue
        current,scaled=check!();centered=current.-mean(current)
        push!(outputs,centered);push!(differences,centered.-previous)
        length(outputs)>5 && (popfirst!(outputs);popfirst!(differences))
        proposal=CE.anderson_candidate(outputs,differences)
        if !isnothing(proposal)
            beta=PCP._copy_to_backend(backend,Float32.(proposal));trial,trial_error=check!()
            if trial_error<.9scaled;current=trial;scaled=trial_error
            else;beta=PCP._copy_to_backend(backend,Float32.(current));end
        end
        previous=current.-mean(current)
        if scaled<=1.2 || iteration%500==0 || iteration==maxiters
            w=weights(g,a,current,eta);stats=residual(g,w,a,b)
            if stats.l1<=tolerance && stats.relative<=maxrelative && stats.source<=1e-10
                return (;weights=w,beta=current.+g.coloffset,iterations=iteration,primal_iterations=0,error=stats)
            end
            if stats.l1<.01 && stats.relative<.1
                corrected=polish(g,w,a,b,backend;tolerance,maxrelative,deadline)
                if !isnothing(corrected)
                    return (;weights=corrected.weights,beta=current.+g.coloffset.+eta.*corrected.correction,
                        iterations=iteration,primal_iterations=corrected.iterations,error=corrected.error)
                end
            end
        end
        iteration%1000==0 && (println("Sparse iteration=",iteration," scaled_residual=",scaled);flush(stdout))
    end
    error("sparse refinement did not converge")
end
end
