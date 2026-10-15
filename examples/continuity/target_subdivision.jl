# CPU moment projection after the KA/oneAPI native-source fit.
module TargetSubdivision
using HiGHS,LinearAlgebra,SparseArrays,Statistics,H3
const H=HiGHS

function split_cell(points,mass,delta;limit=20.)
    n=length(mass);dimensions=size(points,1);cells=size(delta,2)
    1<=dimensions<=4&&size(points,2)==n&&size(delta,1)==dimensions||error("moment dimensions differ")
    all(isfinite,points)&&all(isfinite,delta)&&all(x->isfinite(x)&&x>0,mass)||error("invalid cell input")
    maximum(abs.(sum(delta;dims=2)))<=1e-10*max(1.,maximum(abs,delta))||error("offsets must sum to zero")
    n*cells<=2_000_000&&limit>0||error("cell solve budget exceeded")
    mass=mass/sum(mass);centre=points*mass;centered=points.-centre
    rotation=transpose(svd(hcat(centered,zeros(dimensions,dimensions));full=false).U)
    scale=max.(sqrt.(sum(abs2,rotation*centered;dims=2)./n),1e-9)
    z=(rotation*centered)./scale;z.-=z*mass
    dz=(rotation*delta)./scale
    width=dimensions+1;nr=n+width*(cells-1);nc=n*cells+1
    rows=Int32[];columns=Int32[];values=Float64[]
    rhs=vcat(ones(n),repeat(vcat(1.,zeros(dimensions)),cells-1))
    for j in 1:cells,i in 1:n
        col=(j-1)*n+i;push!(rows,i);push!(columns,col);push!(values,1.)
        if j<cells
            row=n+width*(j-1)+1;push!(rows,row);push!(columns,col);push!(values,cells*mass[i])
            for l in 1:dimensions
                push!(rows,row+l);push!(columns,col);push!(values,cells*mass[i]*z[l,i])
            end
        end
    end
    for j in 1:cells-1,l in 1:dimensions
        push!(rows,n+width*(j-1)+1+l);push!(columns,nc);push!(values,-dz[l,j])
    end
    matrix=sparse(rows,columns,values,nr,nc);cost=zeros(nc);cost[end]=-1.
    handle=H.Highs_create();handle==C_NULL&&error("could not create HiGHS")
    check(status)=status>=0||error("HiGHS call failed: $status")
    try
        check(H.Highs_setBoolOptionValue(handle,"output_flag",0))
        check(H.Highs_setIntOptionValue(handle,"threads",1))
        check(H.Highs_setDoubleOptionValue(handle,"time_limit",limit))
        check(H.Highs_setDoubleOptionValue(handle,"primal_feasibility_tolerance",1e-9))
        check(H.Highs_setDoubleOptionValue(handle,"small_matrix_value",1e-12))
        warm=n>=128;started=time()
        check(H.Highs_passLp(handle,nc,nr,nnz(matrix),H.kHighsMatrixFormatColwise,H.kHighsObjSenseMinimize,0.,
            warm ? zeros(nc) : cost,zeros(nc),vcat(fill(Inf,nc-1),warm ? 0. : 1.),rhs,rhs,
            Int32.(matrix.colptr.-1),Int32.(matrix.rowval.-1),matrix.nzval))
        if warm
            # A feasible uniform plan gives a sparse basis before optimization.
            # The zero-iteration run initializes the HiGHS worker scheduler.
            check(H.Highs_setStringOptionValue(handle,"presolve","off"))
            check(H.Highs_setIntOptionValue(handle,"simplex_iteration_limit",0))
            check(H.Highs_run(handle))
            check(H.Highs_setIntOptionValue(handle,"simplex_iteration_limit",typemax(Cint)))
            seed=vcat(fill(1/cells,n*cells),0.)
            check(H.Highs_crossover(handle,nc,nr,seed,zeros(nc),zeros(nr)))
            H.Highs_getModelStatus(handle)==H.kHighsModelStatusOptimal||error("cell warm start residual")
            check(H.Highs_changeColCost(handle,nc-1,-1.))
            check(H.Highs_changeColBounds(handle,nc-1,0.,1.))
            check(H.Highs_setIntOptionValue(handle,"simplex_strategy",4))
            check(H.Highs_setDoubleOptionValue(handle,"time_limit",max(.001,limit-(time()-started))))
        end
        check(H.Highs_run(handle));status=H.Highs_getModelStatus(handle)
        status in (H.kHighsModelStatusOptimal,H.kHighsModelStatusTimeLimit)||error("cell subdivision status $status")
        solution=zeros(nc);check(H.Highs_getSolution(handle,solution,C_NULL,C_NULL,C_NULL))
        minimum(solution)>=-1e-8&&solution[end]<=1+1e-8||error("cell LP residual")
        weights=reshape(max.(solution[1:end-1],0.),n,cells).*mass
        for i in 1:n
            total=sum(view(weights,i,:))
            total>0||error("cell source residual")
            weights[i,:].*=mass[i]/total
        end
        column_mass=sum(weights;dims=1)
        maximum(abs.(column_mass.*cells.-1))<1e-6||error("cell target residual")
        amplitude=clamp(solution[end],0.,1.);expected=centre.+amplitude.*delta
        actual=points*weights./column_mass;spatial=1:min(3,dimensions)
        maximum(sqrt.(sum(abs2,actual[spatial,:].-expected[spatial,:];dims=1)))<=1e-7||error("cell geographic residual")
        dimensions<4||all(>(0),expected[4,:])&&maximum(abs.(actual[4,:]./expected[4,:].-1))<=1e-6||error("cell density residual")
        return (;weights,amplitude,optimal=status==H.kHighsModelStatusOptimal,status=Int(status))
    finally
        H.Highs_destroy(handle)
    end
end

function subdivide(part,factor;density=true,limit=20.,deadline=Inf)
    2<=factor<=5||error("factor must be 2 to 5")
    (;meta,source,target,weights)=part;n=length(meta.ids);m=length(meta.targets)
    points=density ? vcat(meta.xyz,transpose(meta.population./H3.API.cellAreaKm2.(meta.ids))) : meta.xyz
    dimensions=size(points,1);q=zeros(dimensions,m);b=zeros(m);groups=[Int[] for _ in 1:m]
    for e in eachindex(weights)
        i,j=source[e],target[e];push!(groups[j],e);b[j]+=weights[e]
        for l in 1:dimensions;q[l,j]+=weights[e]*points[l,i];end
    end
    all(>(0),b)||error("empty coarse target");q./=transpose(b)
    lookup=Dict((x,y)=>j for (j,(x,y,c)) in enumerate(meta.targets))
    s=Int32[];t=Int32[];w=Float64[];targets=Tuple{Int,Int,Int}[];records=NamedTuple[]
    offsets=[(2ix-factor-1,2iy-factor-1) for ix in 1:factor for iy in 1:factor]
    for j in 1:m
        time()<deadline||error("subdivision deadline reached")
        x,y,code=meta.targets[j];derivative=zeros(dimensions,2)
        for (axis,(dx,dy)) in enumerate(((2,0),(0,2)))
            left=get(lookup,(x-dx,y-dy),j);right=get(lookup,(x+dx,y+dy),j);width=2*((left!=j)+(right!=j))
            width>0&&(derivative[:,axis]=(q[:,right]-q[:,left])/width)
        end
        delta=hcat([derivative*[dx/factor,dy/factor] for (dx,dy) in offsets]...)
        es=groups[j];ids=source[es];mass=weights[es];reason="";result=nothing
        elapsed=@elapsed try
            result=split_cell(points[:,ids],mass,delta;limit=min(limit,deadline-time()))
        catch err
            reason=sprint(showerror,err)
            # The fallback changes no coarse mass or moment, but is not sharp.
            (startswith(reason,"cell subdivision status")||startswith(reason,"cell ")&&endswith(reason,"residual"))||rethrow()
            result=(;weights=repeat(mass./sum(mass),1,factor^2)./factor^2,amplitude=0.,optimal=false,status=-1)
        end
        push!(records,(;target=j,seconds=elapsed,amplitude=result.amplitude,optimal=result.optimal,solver_status=result.status,reason))
        for (k,(dx,dy)) in enumerate(offsets)
            position=(factor*x+dx,factor*y+dy,code)
            all(v->typemin(Int16)<=v<=typemax(Int16),position[1:2])||error("target coordinate overflow")
            push!(targets,position);fine=length(targets)
            for a in eachindex(ids)
                value=result.weights[a,k]*sum(mass);value>1e-20||continue
                push!(s,ids[a]);push!(t,fine);push!(w,value)
            end
        end
    end
    a=zeros(n);expected=zeros(n);mass=zeros(length(targets));moments=zeros(dimensions,length(targets))
    for e in eachindex(weights);expected[source[e]]+=weights[e];end
    for e in eachindex(w)
        i,j=s[e],t[e];a[i]+=w[e];mass[j]+=w[e]
        for l in 1:dimensions;moments[l,j]+=w[e]*points[l,i];end
    end
    source_error=maximum(abs.(a./expected.-1));target_error=maximum(abs.(mass./repeat(b./factor^2;inner=factor^2).-1))
    source_error<=1e-10&&target_error<=1e-6||error("subdivision mass check failed")
    moments./=transpose(mass)
    anchors=Dict{Int,String}()
    # Keep each city in its original coarse target.
    for (row,name) in part.labels
        candidates=findall(e->s[e]==source[row]&&div(t[e]-1,factor^2)+1==target[row],eachindex(w))
        isempty(candidates)&&error("city contribution lost")
        anchors[candidates[argmax(w[candidates])]]=name
    end
    result=(;meta=merge(meta,(;targets)),source=s,target=t,weights=w,labels=anchors)
    (;part=result,records,moments,source_error,target_error)
end
end
