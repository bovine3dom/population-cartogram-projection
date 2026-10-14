# Load experiment.jl, sparse_refinement.jl, and mobile_export.jl first.
module NativeHierarchy
using ..ContinuityExperiment
using ..SparseRefinement
using ..MobileExport
using LinearAlgebra,Statistics,Serialization,Dates
const CE=ContinuityExperiment
const SR=SparseRefinement
const ME=MobileExport

function xyz(ids)
    result=zeros(3,length(ids))
    for (i,id) in enumerate(ids)
        g=CE.H3.API.cellToLatLng(id)
        result[:,i]=[cos(g.lat)*cos(g.lng),cos(g.lat)*sin(g.lng),sin(g.lat)]
    end
    result
end

function retain(source,target,w,n,m;fraction=1-1e-8)
    keep=falses(length(w))
    for (index,count) in ((source,n),(target,m))
        ptr,rows=ME.group_rows(index,count)
        for i in 1:count
            r=view(rows,ptr[i]:ptr[i+1]-1);sort!(r;by=e->w[e],rev=true)
            threshold=fraction*sum(e->w[e],r);mass=0.
            for e in r
                w[e]>0 || continue
                keep[e]=true;mass+=w[e];mass>=threshold&&break
            end
        end
    end
    findall(keep)
end

function source_ratio(source,w,a)
    ptr,rows=ME.group_rows(source,length(a));count=0
    for i in eachindex(a)
        values=sort(w[rows[ptr[i]:ptr[i+1]-1]];rev=true)
        count+=searchsortedfirst(cumsum(values),.995a[i])
    end
    count/length(a)
end

# Add links only where disconnected components have different mass totals.
function bridge!(support,a,m)
    n=length(a);parent=collect(1:n+m)
    function root(i)
        while parent[i]!=i;parent[i]=parent[parent[i]];i=parent[i];end
        i
    end
    for (i,js) in enumerate(support),j in js
        parent[root(i)]=root(n+j)
    end
    sources=Dict{Int,Vector{Int}}();targets=Dict{Int,Vector{Int}}()
    for i in 1:n;push!(get!(sources,root(i),Int[]),i);end
    for j in 1:m;push!(get!(targets,root(n+j),Int[]),j);end
    balance=Dict(k=>sum(a[get(sources,k,Int[])])-length(get(targets,k,Int[]))/m for k in union(keys(sources),keys(targets)))
    recipients=reduce(vcat,[get(targets,k,Int[]) for (k,v) in balance if v < -1e-10];init=Int[])
    for (k,excess) in balance
        excess>1e-10 || continue
        ids=sort(sources[k];by=i->a[i],rev=true);mass=0.
        goal=min(sum(a[ids]),2excess+min(.001,.1sum(a[ids])))
        for i in ids
            union!(support[i],recipients);mass+=a[i];mass>=goal&&break
        end
    end
    length(balance)
end

function prepare(guide,path)
    meta=guide.meta;code=first(meta.codes)
    target=CE.DataFrame(x=[t[1] for t in meta.targets],y=[t[2] for t in meta.targets])
    d=CE.country(path,code;target,dense=false)
    all(id->CE.H3.API.getResolution(id)==6,d.source.id)||error("expected native H3-6")
    ids=sort!(unique(CE.H3.API.cellToParent.(d.source.id,5)))
    lookup=Dict(id=>i for (i,id) in enumerate(ids))
    parent=[lookup[CE.H3.API.cellToParent(id,5)] for id in d.source.id]
    children=[Int[] for _ in ids];a=zeros(length(ids))
    for (i,p) in enumerate(parent);push!(children[p],i);a[p]+=d.a[i];end
    reference=ME.reference_stats(guide);q=copy(reference.target_xyz)
    q./=sqrt.(sum(abs2,q;dims=1))
    (;guide,d,ids,parent,children,a,xyz=xyz(ids),q,reference)
end

function project(state,backend;radius=1,reserve=1e-8,deadline=Inf)
    (;guide,d,ids,a,xyz,q)=state;n=length(ids);m=length(d.b)
    old=Dict(id=>i for (i,id) in enumerate(guide.meta.ids))
    positions=Dict((t[1],t[2])=>j for (j,t) in enumerate(guide.meta.targets))
    priors=Vector{Dict{Int,Float64}}(undef,n);support=[Set{Int}() for _ in 1:n]
    for (p,id) in enumerate(ids)
        i=get(old,id,0);prior=Dict{Int,Float64}()
        if i>0
            rows=view(guide.index.source_rows,guide.index.source_ptr[i]:guide.index.source_ptr[i+1]-1)
            for r in rows;prior[guide.index.target[r]]=get(prior,guide.index.target[r],0.)+guide.weight[r];end
            total=sum(Base.values(prior));mass=0.
            for j in sort!(collect(keys(prior));by=j->prior[j],rev=true)
                push!(support[p],j);mass+=prior[j];mass>=.999999total&&break
            end
        else
            distance=[sum((xyz[l,p]-q[l,j])^2 for l in 1:3) for j in 1:m]
            for j in partialsortperm(distance,1:min(3,m));prior[j]=1.;push!(support[p],j);end
        end
        priors[p]=prior
        for j in collect(support[p]),dx in -2radius:2:2radius,dy in -2radius:2:2radius
            t=guide.meta.targets[j];k=get(positions,(t[1]+dx,t[2]+dy),0)
            k>0&&push!(support[p],k)
        end
    end
    covered=falses(m);for js in support,j in js;covered[j]=true;end
    for j in findall(!,covered)
        p=argmin([sum((xyz[l,i]-q[l,j])^2 for l in 1:3) for i in 1:n]);push!(support[p],j)
    end
    components=bridge!(support,a,m)
    s=Int32[];t=Int32[];cost=Float64[]
    for i in 1:n
        js=sort!(collect(support[i]));prior=priors[i]
        values=[get(prior,j,0.) for j in js];total=sum(values)
        total>0 || error("empty prior")
        values./=total;values.+=reserve/length(js);values./=sum(values)
        for (j,w) in zip(js,values);push!(s,i);push!(t,j);push!(cost,-log(w));end
    end
    g=SR.graph(n,m,s,t,cost)
    result=SR.solve(g,a,d.b,backend;eta=1.,tolerance=1e-6,maxrelative=1e-4,maxiters=5000,deadline=min(deadline,time()+180))
    keep=retain(g.source,g.target,result.weights,n,m)
    source=g.source[keep];target=g.target[keep];w=result.weights[keep]
    sums=zeros(n);for (i,v) in zip(source,w);sums[i]+=v;end
    w.*=a[source]./sums[source]
    check=SR.residual((;n,m,source,target),w,a,d.b)
    check.l1<=1e-5 && check.relative<=.0003 && check.source<=1e-10 || error("coarse projection failed checks")
    (;source,target,weights=w,components,full_edges=length(cost),check)
end

function split_sources(state,projection,backend;etas=(1e-5,3e-6,1e-6),goal=nothing,deadline=Inf)
    (;d,children,xyz,q)=state
    isnothing(goal) && (goal=source_ratio(state.guide.index.source,state.guide.weight,state.reference.source_sum))
    s=Int32[];t=Int32[];cost=Float64[]
    for g in eachindex(projection.weights),i in children[projection.source[g]]
        push!(s,i);push!(t,g)
        push!(cost,-sum((d.xyz[l,i]-xyz[l,projection.source[g]])*q[l,projection.target[g]] for l in 1:3))
    end
    graph=SR.graph(length(d.a),length(projection.weights),s,t,cost)
    beta=nothing;best=nothing;records=NamedTuple[]
    for eta in etas
        result=nothing
        elapsed=@elapsed try
            result=SR.solve(graph,d.a,projection.weights,backend;eta,initial_beta=beta,tolerance=1e-6,maxrelative=1e-4,maxiters=2500,deadline=min(deadline,time()+120))
        catch err
            message=sprint(showerror,err)
            (occursin("did not converge",message)||occursin("deadline reached",message)) || rethrow()
            isnothing(best)&&rethrow()
        end
        isnothing(result)&&break
        beta=result.beta;ratio=source_ratio(graph.source,result.weights,d.a)
        push!(records,(;eta,elapsed,ratio995=ratio,result.error...))
        println((;code=d.code,stage="source",last(records)...));flush(stdout)
        best=(;source=graph.source,target=projection.target[graph.target],weights=result.weights,eta,ratio)
        ratio<=goal&&break
    end
    isnothing(best)&&error("no valid native source split")
    (;best...,records)
end

function inherited(state,projection)
    source=Int32[];target=Int32[];weights=Float64[]
    for g in eachindex(projection.weights)
        p=projection.source[g]
        for i in state.children[p]
            push!(source,i);push!(target,projection.target[g])
            push!(weights,projection.weights[g]*state.d.a[i]/state.a[p])
        end
    end
    (;source,target,weights,eta=NaN,ratio=source_ratio(source,weights,state.d.a),records=NamedTuple[])
end

function moments(source,target,weights,xyz,m)
    q=zeros(3,m);mass=zeros(m)
    @inbounds for e in eachindex(weights)
        i,j=source[e],target[e];w=weights[e];mass[j]+=w
        for l in 1:3;q[l,j]+=w*xyz[l,i];end
    end
    all(>(0),mass)||error("missing target mass")
    (;q=q./transpose(mass),mass)
end

function pack_part(state,fit;fraction=1-1e-5,max_shift_km=2.)
    (;d,guide,children,ids)=state;n=length(d.a);m=length(d.b)
    keep=retain(fit.source,fit.target,fit.weights,n,m;fraction)
    s=fit.source[keep];t=fit.target[keep];w=fit.weights[keep]
    sums=zeros(n);for (i,v) in zip(s,w);sums[i]+=v;end
    w.*=d.a[s]./sums[s]
    stats=SR.residual((;n,m,source=s,target=t),w,d.a,d.b)
    stats.l1<=1e-4 && stats.relative<=.001 && stats.source<=1e-10 || error("packed country failed mass checks")
    original=moments(fit.source,fit.target,fit.weights,d.xyz,m)
    packed=moments(s,t,w,d.xyz,m)
    shift=6371sqrt(maximum(sum(abs2,packed.q.-original.q;dims=1)))
    shift<=max_shift_km || error("packed country failed centre check")
    parent_lookup=Dict(id=>p for (p,id) in enumerate(ids));labels=Dict{Int32,String}();fallback=0
    for (old_i,name) in guide.meta.labels
        p=get(parent_lookup,guide.meta.ids[old_i],0)
        if p==0
            fallback+=1;i=argmin([sum((d.xyz[l,j]-guide.meta.xyz[l,old_i])^2 for l in 1:3) for j in 1:n])
        else
            cs=children[p];i=cs[argmax(d.source.value[cs])]
        end
        labels[i]=haskey(labels,i) ? labels[i]*", "*name : name
    end
    anchors=Dict{Int,String}()
    for (i,name) in labels
        rows=findall(==(i),s);r=rows[argmax(w[rows])];anchors[r]=name
    end
    meta=(ids=d.source.id,population=d.source.value,codes=fill(d.code,n),targets=guide.meta.targets,xyz=d.xyz,labels)
    part=(;meta,source=s,target=t,weights=w,labels=anchors)
    (;part,stats,label_fallbacks=fallback,ratio995=source_ratio(s,w,d.a),retained=fraction,max_centre_shift_km=shift)
end
end
