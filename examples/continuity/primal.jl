# Included inside ContinuityExperiment. Sparse weights are temporary; plans stay implicit.
@kernel function sparse_scale_reduce!(out,layout,scale,mass,output_offset)
    lane=@index(Local,Linear)
    group=@index(Group,Linear)
    row=output_offset+group
    totals=@localmem Float32 (32,)
    total=0.0f0
    for entry in (layout.ptr[row]+lane-1):32:(layout.ptr[row+1]-1)
        total+=layout.values[entry]*scale[layout.indices[entry]]
    end
    totals[lane]=total
    @synchronize
    for offset in (16,8,4,2,1)
        if lane<=offset
            totals[lane]+=totals[lane+offset]
        end
        @synchronize
    end
    group=@index(Group,Linear)
    if lane==1
        out[output_offset+group]=mass[output_offset+group]/totals[1]
    end
end

function sparse_primal_arrays(p,c;budget,tolerance=1e-4,block_pairs=1_000_000)
    budget>=0 && tolerance>0 && block_pairs>0 || error("invalid sparse refinement limits")
    n,m=size(p)
    limit=min(div(budget-4(n+m+2),16),typemax(Int32)-1)
    limit>=max(n,m) || return nothing
    # Before scaling, each row and column loses at most this relative mass.
    fraction=.01min(tolerance,.001)
    threshold=fraction.*min.(minimum(c.b)/n,c.a./m)
    rowcount=zeros(Int32,n);colcount=zeros(Int32,m);edges=Ref(0)
    block=min(n,max(1,div(block_pairs,m)))
    buffer=Matrix{Float64}(undef,block,m)
    function visit(f)
        for firstrow in 1:block:n
            rows=firstrow:min(n,firstrow+block-1)
            logs=view(buffer,1:length(rows),:)
            logblock!(logs,p,rows)
            @inbounds for j in 1:m,(k,i) in enumerate(rows)
                weight=exp(logs[k,j]);value=Float32(weight)
                if weight>=threshold[i] && value>0
                    f(i,j,value) || return false
                end
            end
        end
        return true
    end
    counted=visit() do i,j,value
        edges[]+=1
        edges[]<=limit || return false
        rowcount[i]+=1;colcount[j]+=1
        return true
    end
    counted && all(>(0),rowcount) && all(>(0),colcount) || return nothing
    rowptr=Int32[1;1 .+ cumsum(rowcount)];colptr=Int32[1;1 .+ cumsum(colcount)]
    columns=Vector{Int32}(undef,edges[]);rowindices=similar(columns)
    rowvalues=Vector{Float32}(undef,edges[]);colvalues=similar(rowvalues)
    nextrow=copy(rowptr[1:end-1]);nextcol=copy(colptr[1:end-1])
    visit() do i,j,value
        r,t=nextrow[i],nextcol[j]
        columns[r]=j;rowvalues[r]=value;nextrow[i]+=1
        rowindices[t]=i;colvalues[t]=value;nextcol[j]+=1
        return true
    end
    nextrow==rowptr[2:end] && nextcol==colptr[2:end] || error("sparse support changed during construction")
    return (rows=(ptr=rowptr,indices=columns,values=rowvalues,max_count=maximum(rowcount)),
        columns=(ptr=colptr,indices=rowindices,values=colvalues,max_count=maximum(colcount)),
        bytes=16edges[]+4(n+m+2))
end

function compact_sparse_polish(p,c,backend;budget,tolerance=1e-4,block_pairs=1_000_000,kwargs...)
    host=sparse_primal_arrays(p,c;budget,tolerance,block_pairs)
    isnothing(host) && return nothing
    kernel=compact_device(backend,host)
    return compact_scale_plan(p,c,backend,kernel;tolerance,block_pairs,kwargs...)
end

# Reuse the cost cache for accurate primal weights; never form a dense host plan.
function compact_polish(p,c,backend,kernel::AbstractMatrix{Float32};block_pairs=1_000_000,kwargs...)
    block_pairs>0 || error("invalid refinement block size")
    last(p.data.keep)==-Inf && last(p.data.take)==0 || error("refine an unmixed candidate")
    size(kernel)==size(p) || error("wrong refinement cache shape")
    n,m=size(p);block=min(m,max(1,div(block_pairs,n)))
    logs=Matrix{Float64}(undef,n,block);weights=Matrix{Float32}(undef,n,block)
    for firstcol in 1:block:m
        cols=firstcol:min(m,firstcol+block-1)
        logblock!(view(logs,:,1:length(cols)),p,1:n,cols)
        view(weights,:,1:length(cols)).=exp.(view(logs,:,1:length(cols)))
        copyto!(kernel,n*(firstcol-1)+1,weights,1,n*length(cols))
        KA.synchronize(backend) # The next block reuses the host upload buffer.
    end
    return compact_scale_plan(p,c,backend,kernel;block_pairs,kwargs...)
end

function compact_scale_plan(p,c,backend,kernel;tolerance=1e-4,maxiters=1000,
                            block_pairs=1_000_000,max_pairs=8_000_000,commands=Ref(0),work=Ref(0))
    tolerance>0 && maxiters>0 && block_pairs>0 && max_pairs>0 || error("invalid refinement limits")
    last(p.data.keep)==-Inf && last(p.data.take)==0 || error("refine an unmixed candidate")
    n,m=size(p)
    isnothing(p.stats) && compact_stats!(p,c;block_pairs)
    initial_residual=max(sum(abs.(p.stats.target.-c.b))/tolerance,
        maximum(abs.(p.stats.target./c.b.-1))/.001)
    da=PCP._copy_to_backend(backend,Float32.(c.a));db=PCP._copy_to_backend(backend,Float32.(c.b))
    u=PCP._copy_to_backend(backend,ones(Float32,n));v=PCP._copy_to_backend(backend,ones(Float32,m))
    probe=KA.zeros(backend,Float32,m)
    host_v=zeros(Float32,m);host_probe=similar(host_v)
    dense=kernel isa AbstractMatrix
    reduce! = dense ? scale_reduce!(backend,32) : sparse_scale_reduce!(backend,32)
    function update!(out,scale,mass,count,rows)
        layout=dense ? kernel : rows isa Val{true} ? kernel.rows : kernel.columns
        width=dense ? count : layout.max_count
        compact_launches(backend,length(out),max(1,div(max_pairs,width)),commands) do offset,outputs
            if dense
                reduce!(out,layout,scale,mass,count,offset,rows;ndrange=32outputs)
            else
                reduce!(out,layout,scale,mass,offset;ndrange=32outputs)
            end
        end
    end
    for iteration in 1:maxiters
        work[]+=1
        update!(u,v,da,m,Val(true));update!(v,u,db,n,Val(false))
        iteration%20==0 || continue
        update!(u,v,da,m,Val(true));update!(probe,u,db,n,Val(false))
        PCP._copy_to_host!(backend,host_v,v);PCP._copy_to_host!(backend,host_probe,probe)
        all(x->isfinite(x)&&x>0,host_v) && all(x->isfinite(x)&&x>0,host_probe) || return nothing
        ratios=Float64.(host_v)./host_probe
        ready=sum(c.b.*abs.(ratios.-1))<=.8tolerance && maximum(abs.(ratios.-1))<=.0008
        ready || iteration==maxiters || continue
        host_u=PCP._copy_to_host!(backend,zeros(Float32,n),u)
        all(x->isfinite(x)&&x>0,host_u) || return nothing
        correction=log.(Float64.(host_v))
        data=merge(p.data,(;u=copy(p.data.u),v=copy(p.data.v)))
        data.u[:,end].+=log.(Float64.(host_u));data.v[:,end].+=correction
        candidate=CompactPlan(data,p.problems,nothing)
        compact_stats!(candidate,c;normalize=true,block_pairs)
        error=sum(abs.(candidate.stats.target.-c.b))
        relative=maximum(abs.(candidate.stats.target./c.b.-1))
        converged=error<=tolerance && relative<=.001
        improved=max(error/tolerance,relative/.001)<.9initial_residual
        if converged || improved
            return (;plan=candidate,log_beta_correction=correction,marginal_error=error,iterations=iteration,converged)
        end
        # Truncated weights cannot certify the full implicit plan. Fall back.
        dense || return nothing
    end
    return nothing
end
