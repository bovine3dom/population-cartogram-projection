module SoftMomentPacking
using HiGHS,LinearAlgebra,SparseArrays,Statistics,H3
include("../mobile_export.jl")
include("quality.jl")
const ME=MobileExport
const MQ=MobileQuality
const H=HiGHS
anchor_kept(value,original)=isfinite(value)&&value>0&&value>=original*(1-1e-10)
function features(points)
 centered=points.-mean(points;dims=2);scale=max.(sqrt.(sum(abs2,centered;dims=2)./size(points,2)),eps())
 centered./=scale;centered.-=mean(centered;dims=2)
 f=svd(centered;full=false);active=findall(>(maximum(f.S;init=0.)*1e-12),f.S)
 vcat(ones(1,size(points,2)),sqrt(size(points,2)).*f.Vt[active,:])
end
function reduce_block(data,rows,weights,target_mass;limit=10.,floors=nothing,tolerance=.02)
 (;meta,index)=data;sources=unique(index.source[rows]);targets=unique(index.target[rows])
 smap=Dict(s=>i for (i,s) in enumerate(sources));tmap=Dict(t=>j for (j,t) in enumerate(targets))
 ns,nt,nc=length(sources),length(targets),length(rows)
 nc<=ns&&return (;rows,weights,seconds=0.,optimal=true)
 source=Int[smap[index.source[r]] for r in rows];target=Int[tmap[index.target[r]] for r in rows]
 totals=zeros(ns);mx=zeros(ns);my=zeros(ns)
 for k in eachindex(rows)
  i=source[k];x,y,_=meta.targets[index.target[rows[k]]];w=weights[k]
  totals[i]+=w;mx[i]+=w*x;my[i]+=w*y
 end
 mx./=totals;my./=totals
 density=meta.population[sources]./H3.API.cellAreaKm2.(meta.ids[sources])
 f=features(vcat(meta.xyz[:,sources],transpose(density)));nf=size(f,1)
 ns<=nf&&return (;rows,weights,seconds=0.,optimal=true)
 nr=3ns+nf*nt;ri=Int32[];ci=Int32[];va=Float64[];cost=zeros(nc);lower=zeros(nc)
 seed=weights./totals[source]
 for k in eachindex(rows)
  r=rows[k];i,j=source[k],target[k];s=index.source[r];t=index.target[r];x,y,_=meta.targets[t]
  for (row,value) in ((3i-2,1.),(3i-1,x-mx[i]),(3i,y-my[i]))
   push!(ri,row);push!(ci,k);push!(va,value)
  end
  for l in 1:nf
   push!(ri,3ns+nf*(j-1)+l);push!(ci,k);push!(va,totals[i]*meta.population[s]/target_mass[t]*f[l,i])
  end
  cost[k]=totals[i]*((x-mx[i])^2+(y-my[i])^2)
  (r in data.protected||!isnothing(floors)&&floors[r])&&(lower[k]=seed[k])
 end
 matrix=sparse(ri,ci,va,nr,nc);rhs=matrix*seed;lo=copy(rhs);hi=copy(rhs)
 for i in 1:ns
  lo[3i-1]=lo[3i]=-tolerance;hi[3i-1]=hi[3i]=tolerance
 end
 scale=abs.(matrix)*seed
 for i in 1:ns;scale[3i-1]=scale[3i]=1.;end
 scale=max.(scale,1e-12)
 for k in eachindex(matrix.nzval);matrix.nzval[k]/=scale[matrix.rowval[k]];end
 lo./=scale;hi./=scale;cost./=max(maximum(cost),1.)
 full_matrix,full_lo,full_hi=matrix,lo,hi
 pivots=qr(f.*transpose(meta.population[sources].*totals),ColumnNorm()).p[1:nf]
 independent=trues(nr);independent[3 .* pivots .- 2].=false
 matrix=matrix[independent,:];lo=lo[independent];hi=hi[independent];nr=size(matrix,1)
 h=H.Highs_create();h==C_NULL&&error("HiGHS allocation failed");check(x)=x>=0||error("HiGHS call $x")
 try
  check(H.Highs_setBoolOptionValue(h,"output_flag",0));check(H.Highs_setIntOptionValue(h,"threads",1))
  check(H.Highs_setDoubleOptionValue(h,"time_limit",limit));check(H.Highs_setDoubleOptionValue(h,"primal_feasibility_tolerance",1e-10))
  check(H.Highs_setDoubleOptionValue(h,"small_matrix_value",1e-12))
  check(H.Highs_passLp(h,nc,nr,nnz(matrix),H.kHighsMatrixFormatColwise,H.kHighsObjSenseMinimize,0.,cost,lower,ones(nc),lo,hi,Int32.(matrix.colptr.-1),Int32.(matrix.rowval.-1),matrix.nzval))
  seconds=@elapsed check(H.Highs_run(h));status=H.Highs_getModelStatus(h)
  status in (H.kHighsModelStatusOptimal,H.kHighsModelStatusTimeLimit)||error("soft moment status $status")
  solution=zeros(nc);check(H.Highs_getSolution(h,solution,C_NULL,C_NULL,C_NULL))
  minimum(solution)>=-1e-8||error("soft moment negative weight");solution=max.(solution,0.)
  sumrow=zeros(ns);for k in eachindex(solution);sumrow[source[k]]+=solution[k];end
  all(>(0),sumrow)||error("soft moment source lost");solution./=sumrow[source]
  actual=full_matrix*solution
  maximum(max.(full_lo.-actual,actual.-full_hi))<=1e-7||error("soft moment residual")
  dot(cost,solution)<=dot(cost,seed)+1e-7||error("soft moment objective increased")
  maximum(lower.-solution)<=1e-8||error("soft moment lower bound")
  w=solution.*totals[source]
  all(!(r in data.protected)||anchor_kept(w[k],weights[k]) for (k,r) in enumerate(rows))||error("soft moment anchor lost")
  keep=findall(>(0),w)
  (;rows=rows[keep],weights=w[keep],seconds,optimal=status==H.kHighsModelStatusOptimal)
 finally;H.Highs_destroy(h);end
end

function support_ratio(source,w,n)
    ptr,rows=ME.group_rows(source,n);count=0
    for i in 1:n
        values=sort(w[rows[ptr[i]:ptr[i+1]-1]];rev=true)
        count+=searchsortedfirst(cumsum(values),.995sum(values))
    end
    count/n
end

function pack_country(part;factor=1,target_retained=.99,tolerance=.02,
                      source_block=4096,target_block=512,limit=10.,deadline=Inf)
    1<=factor<=5&&0<=target_retained<=1&&isfinite(tolerance)&&tolerance>=0||error("invalid packing limits")
    source_block>0&&target_block>0&&isfinite(limit)&&limit>0||error("invalid block limits")
    time()<deadline||error("packing deadline reached")
    (;meta,source,target,weights)=part;n=length(meta.ids);m=length(meta.targets)
    all(x->isfinite(x)&&x>0,weights)||error("invalid input weights")
    a=meta.population/sum(meta.population);weight=weights./a[source]
    sp,sr=ME.group_rows(source,n);tp,tr=ME.group_rows(target,m)
    ME.sort_groups!(sr,sp,r->weight[r]);ME.sort_groups!(tr,tp,r->weight[r]*meta.population[source[r]])
    protected=Set(keys(part.labels))
    union!(protected,[minimum(view(tr,tp[j]:tp[j+1]-1)) for j in 1:m])
    data=(;meta,index=(;source,target,source_ptr=sp,source_rows=sr,target_ptr=tp,target_rows=tr),weight,protected)
    reference=ME.reference_stats(data)
    maximum(abs.(reference.source_sum.-1))<=1e-10||error("input source mass differs")
    floors=ME.target_floor_rows(data,target_retained)
    srank=invperm(sortperm(meta.ids));trank=invperm(sortperm(meta.targets));nt=cld(m,target_block)
    groups=[(cld(srank[source[r]],source_block)-1)*nt+cld(trank[target[r]],target_block) for r in eachindex(weight)]
    order=sortperm(groups);rows=Int32[];values=Float64[];first=1;blocks=0;nonoptimal=0;failures=NamedTuple[]
    while first<=length(order)
        time()<deadline||error("packing deadline reached")
        last=first
        while last<length(order)&&groups[order[last+1]]==groups[order[first]];last+=1;end
        rr=Int32.(order[first:last]);ww=weight[rr]
        result=try
            reduce_block(data,rr,ww,reference.target_mass;limit=min(limit,deadline-time()),floors,tolerance=tolerance*factor)
        catch err
            message=sprint(showerror,err)
            (startswith(message,"soft moment")||startswith(message,"HiGHS"))||rethrow()
            push!(failures,(;block=blocks+1,rows=length(rr),error=message))
            (;rows=rr,weights=ww,optimal=true)
        end
        nonoptimal+=!result.optimal
        append!(rows,result.rows);append!(values,result.weights);blocks+=1;first=last+1
    end
    order=sortperm(rows);rows=rows[order];values=values[order]
    positions=Dict(r=>i for (i,r) in enumerate(rows))
    all(haskey(positions,r)&&anchor_kept(values[positions[r]],weight[r]) for r in protected)||error("protected anchor lost")
    summary=ME.evaluate(data,rows,reference;weights=values)
    summary.source_sum_error<=1e-10&&summary.target_mass_error_max<=1e-7||error("packed mass check failed")
    summary.inverse_km_max<=.001&&summary.forward_max<=sqrt(2)*tolerance*factor+1e-6||error("packed position check failed")
    summary.target_tv_max<=1-target_retained+1e-6||error("packed target variation check failed")
    names,fields=MQ.probe_fields(meta)
    original,original_mass=MQ.target_values(data,eachindex(weight),weight,fields)
    candidate,candidate_mass=MQ.target_values(data,rows,values,fields)
    queries=MQ.compare_values(original,original_mass,candidate,candidate_mass,names,fields)
    density_error=maximum(abs.(candidate[1,:]./original[1,:].-1))
    density_error<=1e-6||error("packed density check failed")
    source_tv=copy(reference.source_sum)
    for (r,w) in zip(rows,values);source_tv[source[r]]+=abs(w-weight[r])-weight[r];end
    labels=Dict(positions[r]=>name for (r,name) in part.labels)
    packed=(;meta,source=source[rows],target=target[rows],weights=values.*a[source[rows]],labels)
    report=(;original_rows=length(weight),blocks,failed_blocks=length(failures),nonoptimal_blocks=nonoptimal,target_retained,tolerance,
        source_tv_max=maximum(source_tv)/2,density_relative_error=density_error,
        ratio995=support_ratio(source[rows],values,n),forward_coarse_max=summary.forward_max/factor,
        protected_rows=length(protected),summary...)
    (;part=packed,report,queries,failures)
end
end
