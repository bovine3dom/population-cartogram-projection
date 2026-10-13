module MomentReduction
using HiGHS, LinearAlgebra, SparseArrays, Statistics, H3

# Row scaling and an orthogonal basis avoid nearly dependent geographic axes.
function features(points)
    centered=points.-mean(points;dims=2)
    scale=sqrt.(sum(abs2,centered;dims=2)./size(points,2))
    centered./=max.(scale,eps(Float64))
    f=svd(centered;full=false)
    active=findall(>(maximum(f.S;init=0.)*1e-12),f.S)
    return vcat(ones(1,size(points,2)),sqrt(size(points,2)).*f.Vt[active,:])
end

function reduce_block(data,rows,weights,target_mass;forward=true,density=false,limit=300.,verbose=false)
    (;meta,index)=data
    !isempty(rows) && length(rows)==length(weights) && all(w->isfinite(w)&&w>0,weights) || error("invalid block")
    sources=unique(index.source[rows]);targets=unique(index.target[rows])
    smap=zeros(Int32,length(meta.ids));smap[sources]=1:length(sources)
    tmap=zeros(Int32,length(meta.targets));tmap[targets]=1:length(targets)
    source_points=meta.xyz[:,sources]
    if density
        values=meta.population[sources]./H3.API.cellAreaKm2.(meta.ids[sources])
        source_points=vcat(source_points,transpose(values))
    end
    a=features(source_points)
    b=forward ? features(Float64[meta.targets[t][k] for k in 1:2,t in targets]) : ones(1,length(targets))
    ns,nt,nc=length(sources),length(targets),length(rows)
    sf,tf=size(b,1),size(a,1);nr=sf*ns+tf*nt
    # Full row or column rank leaves no direction that preserves the moments.
    if ns<=tf || nt<=sf || nc<=nr-sf*tf
        return (;rows,weights,seconds=0.,residual=0.,constraints=nr,skipped=true)
    end
    width=sf+tf
    width*nc<typemax(Int32) || error("block is too large")
    ptr=Int32.(1:width:1+width*nc)
    ri=Vector{Int32}(undef,width*nc);va=Vector{Float64}(undef,width*nc);lower=zeros(nc)
    for (col,r) in enumerate(rows)
        s,t=index.source[r],index.target[r];i,j=smap[s],tmap[t];start=ptr[col]-1
        if haskey(meta.labels,s) && r==index.source_rows[index.source_ptr[s]]
            lower[col]=.5data.weight[r]
        end
        for k in 1:sf
            ri[start+k]=sf*(i-1)+k;va[start+k]=b[k,j]
        end
        for k in 1:tf
            ri[start+sf+k]=sf*ns+tf*(j-1)+k
            va[start+sf+k]=meta.population[s]/target_mass[t]*a[k,i]
        end
    end
    all(weights .>= lower.-1e-8) || error("label anchor was lost")
    matrix=SparseMatrixCSC(nr,nc,ptr,ri,va);rhs=matrix*weights
    # The two sets of moment equations share sf*tf exact dependencies.
    pivots=qr(a,ColumnNorm()).p[1:tf]
    independent=trues(nr)
    for i in pivots
        independent[sf*(i-1)+1:sf*i].=false
    end
    full_matrix,full_rhs=matrix,rhs
    matrix=matrix[independent,:];rhs=rhs[independent];nr=size(matrix,1)
    ptr,ri,va=matrix.colptr,matrix.rowval,matrix.nzval
    scale=maximum(weights)
    seed=weights./scale;rhs=rhs./scale;lower=lower./scale
    h=HiGHS.Highs_create();h==C_NULL && error("could not create HiGHS")
    check(status)=status>=0 || error("HiGHS call failed: $status")
    try
        check(HiGHS.Highs_setBoolOptionValue(h,"output_flag",Int(verbose)))
        check(HiGHS.Highs_setIntOptionValue(h,"threads",1))
        check(HiGHS.Highs_setDoubleOptionValue(h,"time_limit",limit))
        check(HiGHS.Highs_setDoubleOptionValue(h,"small_matrix_value",1e-12))
        check(HiGHS.Highs_setDoubleOptionValue(h,"primal_feasibility_tolerance",1e-9))
        check(HiGHS.Highs_passLp(h,nc,nr,length(va),HiGHS.kHighsMatrixFormatColwise,
            HiGHS.kHighsObjSenseMinimize,0.,zeros(nc),lower,fill(Inf,nc),rhs,rhs,
            ptr.-Int32(1),ri.-Int32(1),va))
        # HiGHS 1.15.1 direct crossover needs the worker scheduler initialized.
        # A zero-iteration run initializes it without changing the supplied seed.
        check(HiGHS.Highs_setStringOptionValue(h,"presolve","off"))
        check(HiGHS.Highs_setIntOptionValue(h,"simplex_iteration_limit",0))
        check(HiGHS.Highs_run(h))
        check(HiGHS.Highs_setIntOptionValue(h,"simplex_iteration_limit",typemax(Cint)))
        seconds=@elapsed status=HiGHS.Highs_crossover(h,nc,nr,seed,zeros(nc),zeros(nr))
        check(status)
        model_status=HiGHS.Highs_getModelStatus(h)
        model_status==HiGHS.kHighsModelStatusOptimal || error("crossover status $status, model $model_status after $seconds seconds")
        solution=zeros(nc);check(HiGHS.Highs_getSolution(h,solution,C_NULL,C_NULL,C_NULL))
        minimum(solution)>=-1e-8 || error("negative reduced weight")
        maximum(lower.-solution)<=1e-8 || error("label bound failed")
        solution=max.(solution,0.).*scale
        residual=maximum(abs.(full_matrix*solution.-full_rhs))
        residual<=1e-6 || error("moment residual $residual")
        keep=findall(>(0),solution)
        length(keep)<=nr+count(>(0),lower) || error("crossover did not give a sparse solution")
        return (;rows=rows[keep],weights=solution[keep],seconds,residual,constraints=nr,skipped=false)
    finally
        HiGHS.Highs_destroy(h)
    end
end
end
