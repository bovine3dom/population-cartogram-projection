module ContinuityExperiment

using Arrow, CSV, DataFrames, H3, LinearAlgebra, Statistics, Serialization
using PopulationCartogramProjection
import KernelAbstractions as KA
using KernelAbstractions: @kernel, @index, @localmem, @synchronize
const PCP = PopulationCartogramProjection
include(joinpath(@__DIR__, "..", "common.jl"))

function checkpoint(path,value)
    temporary=path*".tmp"
    serialize(temporary,value)
    mv(temporary,path;force=true)
    return nothing
end

@inline pair_cost(cost::AbstractMatrix,i,j) = cost[i,j]
@inline function pair_cost(c::NamedTuple,i,j)
    s,t=c.source,c.target
    base=PCP._matrix_free_cost(s[1][i],s[2][i],s[3][i],s[4][i],
                               t[1][j],t[2][j],t[3][j],t[4][j],c.scale)
    value = base + muladd(c.geo[1,i],c.force[1,j],
                         muladd(c.geo[2,i],c.force[2,j],c.geo[3,i]*c.force[3,j]))
    return (value-c.source_offset[i])-c.target_offset[j]
end

# Exact reductions: experimental costs must not use the core's spatial pruning.
@kernel function dense_reduce!(out, cost, dual, mass, eta, n, ::Val{ROWS}) where ROWS
    lane = @index(Local, Linear)
    j = @index(Group, Linear)
    maxima = @localmem Float32 (32,)
    totals = @localmem Float32 (32,)
    high = -Inf32
    for i in lane:32:n
        c = ROWS ? pair_cost(cost,j,i) : pair_cost(cost,i,j)
        high = max(high, dual[i] - c)
    end
    maxima[lane] = high
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            maxima[lane] = max(maxima[lane], maxima[lane + offset])
        end
        @synchronize
    end
    j = @index(Group, Linear)
    total = 0.0f0
    for i in lane:32:n
        c = ROWS ? pair_cost(cost,j,i) : pair_cost(cost,i,j)
        total += exp((dual[i] - c - maxima[1]) / eta)
    end
    totals[lane] = total
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            totals[lane] += totals[lane + offset]
        end
        @synchronize
    end
    j = @index(Group, Linear)
    if lane == 1
        out[j] = eta * log(mass[j]) - maxima[1] - eta * log(totals[1])
    end
end

@kernel function scale_reduce!(out,kernel,scale,mass,n,::Val{ROWS}) where ROWS
    lane=@index(Local,Linear)
    j=@index(Group,Linear)
    totals=@localmem Float32 (32,)
    total=0.0f0
    for i in lane:32:n
        value=ROWS ? kernel[j,i] : kernel[i,j]
        total+=value*scale[i]
    end
    totals[lane]=total
    @synchronize
    for offset in (16,8,4,2,1)
        if lane<=offset
            totals[lane]+=totals[lane+offset]
        end
        @synchronize
    end
    j=@index(Group,Linear)
    if lane==1
        out[j]=mass[j]/totals[1]
    end
end

function polish_plan(plan,a,b,backend; tolerance=1e-5,maxiters=500)
    kernel=PCP._copy_to_backend(backend,Float32.(plan))
    da,db=PCP._copy_to_backend(backend,Float32.(a)),PCP._copy_to_backend(backend,Float32.(b))
    u,v=PCP._copy_to_backend(backend,ones(Float32,length(a))),PCP._copy_to_backend(backend,ones(Float32,length(b)))
    host_u,host_v=ones(Float32,length(a)),ones(Float32,length(b))
    update! = scale_reduce!(backend,32)
    for iteration in 1:maxiters
        update!(u,kernel,v,da,length(b),Val(true);ndrange=32length(a))
        update!(v,kernel,u,db,length(a),Val(false);ndrange=32length(b))
        if iteration%20==0
            PCP._copy_to_host!(backend,host_u,u); PCP._copy_to_host!(backend,host_v,v)
            all(x->isfinite(x)&&x>0,host_u) && all(x->isfinite(x)&&x>0,host_v) || return nothing
            result=plan .* host_u .* transpose(host_v)
            result .*= a ./ vec(sum(result;dims=2))
            totals=vec(sum(result;dims=1))
            error=sum(abs.(totals.-b))
            if error<=tolerance && maximum(abs.(totals./b.-1))<=.001
                return (;plan=result,log_beta_correction=log.(Float64.(host_v)),marginal_error=error,iterations=iteration)
            end
        end
    end
    return nothing
end

function reconstruct(cost, beta, a, eta)
    logits = (transpose(Float64.(beta)) .- cost) ./ eta
    logits .-= maximum(logits; dims=2)
    plan = exp.(logits)
    plan .*= a ./ vec(sum(plan; dims=2))
    return plan
end

function sinkhorn(cost,a,b,backend;kwargs...)
    # A target-only offset does not change the optimum. It improves Float32 conditioning.
    offset = vec(minimum(cost;dims=1))
    shifted = Float32.(cost .- transpose(offset))
    dc = PCP._copy_to_backend(backend, shifted)
    return solve_cost(shifted,dc,offset,a,b,backend;kwargs...)
end

function anderson_candidate(outputs,residuals)
    length(outputs)>=2 || return nothing
    r=hcat(residuals...)
    gram=transpose(r)*r
    ridge=max(1e-12*tr(gram),1e-30)
    coefficients=(gram+ridge*I)\ones(length(outputs))
    coefficients ./= sum(coefficients)
    all(isfinite,coefficients) && maximum(abs,coefficients)<=20 || return nothing
    return hcat(outputs...)*coefficients
end

function solve_cost(shifted,dc,offset,a,b,backend;eta=0.002,tolerance=0.00001,maxiters=10000,
                    initial_beta=nothing,anneal=false,accelerate=false)
    if anneal
        iterations=refinement_iterations=0
        result=nothing
        for factor in (64.,16.,4.,1.)
            result=solve_cost(shifted,dc,offset,a,b,backend;eta=eta*factor,
                              tolerance=factor==1 ? tolerance : max(tolerance,1e-3),maxiters,initial_beta,accelerate)
            initial_beta=result.beta
            iterations+=result.iterations
            refinement_iterations+=result.refinement_iterations
            println("Temperature factor $factor: $(result.iterations) dual + $(result.refinement_iterations) primal, residual=$(result.marginal_error)")
            flush(stdout)
        end
        return merge(result,(;iterations,refinement_iterations))
    end
    da, db = PCP._copy_to_backend(backend, Float32.(a)), PCP._copy_to_backend(backend, Float32.(b))
    alpha = KA.zeros(backend,Float32,length(a))
    beta = isnothing(initial_beta) ? KA.zeros(backend,Float32,length(b)) :
        PCP._copy_to_backend(backend,Float32.(initial_beta .- offset))
    host_beta = zeros(Float32, length(b))
    update! = dense_reduce!(backend, 32)
    error = Inf
    best_error=Inf
    stagnant=0
    polish_error=Inf
    last_polish=0
    outputs=Vector{Float64}[]; residuals=Vector{Float64}[]
    block_beta=isnothing(initial_beta) ? zeros(length(b)) : Float64.(initial_beta .- offset)
    block_beta .-= mean(block_beta)
    for iteration in 1:maxiters
        update!(alpha, dc, beta, da, Float32(eta), length(b), Val(true); ndrange=32length(a))
        update!(beta, dc, alpha, db, Float32(eta), length(a), Val(false); ndrange=32length(b))
        if iteration % 50 == 0
            PCP._copy_to_host!(backend, host_beta, beta)
            plan = reconstruct(shifted, host_beta, a, eta)
            error = sum(abs.(vec(sum(plan; dims=1)) .- b))
            max_relative = maximum(abs.(vec(sum(plan;dims=1))./b .- 1))
            if accelerate
                current=Float64.(host_beta); current .-= mean(current)
                push!(outputs,current); push!(residuals,current-block_beta)
                length(outputs)>5 && (popfirst!(outputs);popfirst!(residuals))
                proposal=anderson_candidate(outputs,residuals)
                if !isnothing(proposal)
                    proposed_beta=Float32.(proposal)
                    proposed_plan=reconstruct(shifted,proposed_beta,a,eta)
                    totals=vec(sum(proposed_plan;dims=1))
                    proposed_error=sum(abs.(totals.-b))
                    proposed_relative=maximum(abs.(totals./b.-1))
                    if max(proposed_error/tolerance,proposed_relative/.001)<.9max(error/tolerance,max_relative/.001)
                        host_beta .= proposed_beta
                        beta=PCP._copy_to_backend(backend,host_beta)
                        plan=proposed_plan; error=proposed_error; max_relative=proposed_relative
                    end
                end
                block_beta=Float64.(host_beta); block_beta .-= mean(block_beta)
            end
            stagnant = error >= best_error*(1-1e-3) ? stagnant+1 : 0
            best_error=min(best_error,error)
            if error <= tolerance && max_relative <= 0.001
                return (; plan, beta=Float64.(host_beta).+offset,
                        iterations=iteration, marginal_error=error,polished=false,refinement_iterations=0)
            end
            retry=error<polish_error/2 || (stagnant>=4 && iteration-last_polish>=500)
            if (retry || iteration==maxiters) && error<.05 && max_relative<.5 &&
               (error<.001 || stagnant>=4 || iteration==maxiters)
                polish_error=error
                last_polish=iteration
                refined=polish_plan(plan,a,b,backend;tolerance,maxiters=iteration==maxiters ? 10000 : 500)
                if !isnothing(refined)
                    return (;plan=refined.plan,beta=Float64.(host_beta).+offset.+eta.*refined.log_beta_correction,
                            iterations=iteration,marginal_error=refined.marginal_error,polished=true,
                            refinement_iterations=refined.iterations)
                end
            end
        end
    end
    Base.error("Sinkhorn did not converge: marginal error=$error; eta=$eta")
end

function feature_sinkhorn(c,forces,backend;kwargs...)
    p=hasproperty(c,:problem) ? c.problem : PCP._prepare_problem(c.target,c.source)
    source=(p.source_x_hi,p.source_x_lo,p.source_y_hi,p.source_y_lo)
    target=(p.target_x_hi,p.target_x_lo,p.target_y_hi,p.target_y_lo)
    host=(;source,target,scale=p.inverse_distance_scale,
          geo=Float32.(c.xyz .- mean(c.xyz;dims=2)),force=Float32.(forces .- mean(forces;dims=2)),
          source_offset=zeros(Float32,length(c.a)),target_offset=zeros(Float32,length(c.b)))
    cost=Matrix{Float32}(undef,length(c.a),length(c.b))
    Threads.@threads for j in eachindex(c.b)
        for i in eachindex(c.a)
            cost[i,j]=pair_cost(host,i,j)
        end
    end
    host.source_offset .= vec(minimum(cost;dims=2))
    cost .-= host.source_offset
    host.target_offset .= vec(minimum(cost;dims=1))
    cost .-= transpose(host.target_offset)
    copy_device(x)=PCP._copy_to_backend(backend,x)
    device=(source=map(copy_device,source),target=map(copy_device,target),scale=host.scale,
            geo=copy_device(host.geo),force=copy_device(host.force),
            source_offset=copy_device(host.source_offset),target_offset=copy_device(host.target_offset))
    return solve_cost(cost,device,Float64.(host.target_offset),c.a,c.b,backend;kwargs...)
end

function country(path, code; factor=1)
    raw = DataFrame(Arrow.Table(path))
    all(==(code), raw.country_code) || error("wrong source country")
    allunique(raw.id) || error("duplicate source ids")
    centres = H3.API.cellToLatLng.(raw.id)
    source = DataFrame(id=UInt64.(raw.id), x=[rad2deg(c.lng) for c in centres],
                       y=[rad2deg(c.lat) for c in centres], value=Float64.(raw.population))
    target = load_cartogram(code; factor)
    PCP._validate_inputs(target, source)
    problem = PCP._prepare_problem(target, source)
    cost = Float64[PCP._cost(problem, i, j) for i in 1:nrow(source), j in 1:nrow(target)]
    xyz = hcat([[cos(c.lat)*cos(c.lng), cos(c.lat)*sin(c.lng), sin(c.lat)] for c in centres]...)
    a = source.value ./ sum(source.value)
    b = fill(1 / nrow(target), nrow(target))
    return (; code, source, target, cost, xyz, a, b, problem)
end

function pose_cost(c,angle)
    angle==0 && return c.cost
    source=copy(c.source)
    x=(source.x.-mean(source.x)).*cosd(mean(source.y))
    y=source.y.-mean(source.y)
    source.x=x.*cosd(angle).-y.*sind(angle)
    source.y=x.*sind(angle).+y.*cosd(angle)
    problem=PCP._prepare_problem(c.target,source)
    return [PCP._cost(problem,i,j) for i in eachindex(c.a),j in eachindex(c.b)]
end

function graph(countries; borders=Set([(276,616)]))
    lookup = Dict((r.x, r.y) => (k, j) for (k, c) in enumerate(countries)
                  for (j, r) in enumerate(eachrow(c.target)))
    edges = Tuple{Int,Int,Int,Int}[]
    for ((x, y), (k, j)) in lookup, pos in ((x+2, y), (x, y+2))
        haskey(lookup, pos) || continue
        l, t = lookup[pos]
        (k == l || minmax(countries[k].code, countries[l].code) in borders) || continue
        push!(edges, (k, j, l, t))
    end
    return sort!(edges)
end

function edge_weights(edges, border_share)
    isnothing(border_share) && return fill(1/max(length(edges),1),length(edges))
    0 <= border_share <= 1 || error("border_share must be between zero and one")
    cross = [e[1]!=e[3] for e in edges]
    n = count(cross)
    0 < n < length(edges) || error("explicit border share requires both edge types")
    return [v ? border_share/n : (1-border_share)/(length(edges)-n) for v in cross]
end

function saved_case(path,countries;root=dirname(path))
    row=only(eachrow(CSV.read(joinpath(path,"settings.csv"),DataFrame)))
    masks=filter(isfile,[joinpath(path,"borders.csv"),joinpath(path,"baseline-seams.csv"),joinpath(root,"borders.csv")])
    isempty(masks) && row.border_edges>0 && error("checkpoint has no border mask")
    borders=isempty(masks) ? Set{Tuple{Int,Int}}() :
        Set(minmax(r.country_a,r.country_b) for r in eachrow(CSV.read(first(masks),DataFrame)))
    count(e->e[1]!=e[3],graph(countries;borders))==row.border_edges || error("border mask differs from checkpoint")
    file=joinpath(path,"border-factors.csv")
    border_factors=isfile(file) ? Dict(minmax(r.country_a,r.country_b)=>r.factor for r in eachrow(CSV.read(file,DataFrame))) : Dict()
    settings=Dict(k=>v for (k,v) in pairs(row) if !(k in (:internal_edges,:border_edges)))
    for key in (:form,:internal_form)
        haskey(settings,key) && (settings[key]=Symbol(settings[key]))
    end
    ismissing(settings[:border_share]) && (settings[:border_share]=nothing)
    return (;settings,borders,border_factors)
end

function export_seams(path,countries,plans,edges)
    pairs = sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k != l]))
    isempty(pairs) && return
    CSV.write(path,DataFrame([(; country_a=countries[k].code,country_b=countries[l].code,
        metrics(countries,plans,filter(e -> e[1]==e[3] || minmax(e[1],e[3])==(k,l),edges))...)
        for (k,l) in pairs]))
end

means(c, p) = (c.xyz * p) ./ sum(p; dims=1)

function refined_centres(coarse,plan,fine)
    allunique(coarse.target.parent_cell_id) || error("expected unsubdivided coarse targets")
    factor=round(Int,sqrt(nrow(fine.target)/nrow(coarse.target)))
    factor>0 && factor^2*nrow(coarse.target)==nrow(fine.target) || error("invalid refinement ratio")
    parents=Dict(id=>j for (j,id) in enumerate(coarse.target.parent_cell_id))
    lookup=Dict((r.x,r.y)=>j for (j,r) in enumerate(eachrow(coarse.target)))
    q=means(coarse,plan); q ./= sqrt.(sum(abs2,q;dims=1))
    result=zeros(3,nrow(fine.target))
    for (t,row) in enumerate(eachrow(fine.target))
        j=parents[row.parent_cell_id]
        x,y=coarse.target.x[j],coarse.target.y[j]
        fx,fy=row.x/factor,row.y/factor
        boxes=[(bx,by) for bx in (x-2,x),by in (y-2,y)
               if all(haskey(lookup,pos) for pos in ((bx,by),(bx+2,by),(bx,by+2),(bx+2,by+2)))]
        value=copy(q[:,j])
        if !isempty(boxes)
            distance(b)=max(b[1]-fx,0,fx-b[1]-2)^2+max(b[2]-fy,0,fy-b[2]-2)^2
            bx,by=boxes[argmin(distance.(boxes))]
            a,b,d,z=[lookup[pos] for pos in ((bx,by),(bx+2,by),(bx,by+2),(bx+2,by+2))]
            u,v=(fx-bx)/2,(fy-by)/2
            value=u+v<=1 ? q[:,a]+u*(q[:,b]-q[:,a])+v*(q[:,d]-q[:,a]) :
                          q[:,z]+(1-v)*(q[:,b]-q[:,z])+(1-u)*(q[:,d]-q[:,z])
        else
            for (axis,delta) in ((1,fx-x),(2,fy-y))
                dx,dy=axis==1 ? (2,0) : (0,2)
                left=get(lookup,(x-dx,y-dy),j); right=get(lookup,(x+dx,y+dy),j)
                width=2*((left!=j)+(right!=j))
                width>0 && (value .+= delta.*(q[:,right]-q[:,left])./width)
            end
        end
        result[:,t]=value./norm(value)
    end
    return result
end

function penalty_gradient(countries, plans, edges; scale_km=300.0,
                          weights=fill(1/max(length(edges),1),length(edges)),
                          form=:mean, internal_form=form, saturating=true, reference=nothing, forces_only=false)
    q = [means(c, p) for (c, p) in zip(countries, plans)]
    g = [zeros(size(v)) for v in q]
    tau2 = (scale_km / 6371)^2
    form in (:mean,:distribution) && internal_form in (:mean,:distribution) || error("unknown continuity penalty")
    penalty = 0.0
    for ((k, j, l, t), weight) in zip(edges, weights)
        d = q[k][:, j] - q[l][:, t]
        displacement = !isnothing(reference) && k==l
        displacement && (d -= reference[k][:,j] - reference[l][:,t])
        mean_form = (k==l ? internal_form : form) == :mean || displacement
        squared = mean_form ? sum(abs2,d) : max(0.0,2-2dot(q[k][:,j],q[l][:,t]))
        scaled = squared / (2tau2)
        decay = saturating ? exp(-scaled) : 1.0
        penalty += weight * (saturating ? -expm1(-scaled) : scaled)
        if mean_form
            derivative = weight .* decay .* d ./ tau2
            g[k][:, j] .+= derivative
            g[l][:, t] .-= derivative
        else
            g[k][:,j] .-= weight .* decay .* q[l][:,t] ./ tau2
            g[l][:,t] .-= weight .* decay .* q[k][:,j] ./ tau2
        end
    end
    gradient = forces_only ? [v./sum(p;dims=1) for (v,p) in zip(g,plans)] :
        [(transpose(c.xyz) * v .- sum(q[k] .* v; dims=1)) ./ sum(plans[k]; dims=1)
         for (k, (c, v)) in enumerate(zip(countries, g))]
    return penalty, gradient
end

function triangles(countries)
    result=NTuple{4,Int}[]
    for (k,c) in enumerate(countries)
        lookup=Dict((r.x,r.y)=>j for (j,r) in enumerate(eachrow(c.target)))
        for ((x,y),j) in lookup
            all(haskey(lookup,pos) for pos in ((x+2,y),(x,y+2),(x+2,y+2))) || continue
            right,down,diagonal=[lookup[pos] for pos in ((x+2,y),(x,y+2),(x+2,y+2))]
            push!(result,(k,j,right,down),(k,diagonal,down,right))
        end
    end
    return sort!(result)
end

function fold_penalty_gradient(countries,plans,triangles;area_scale=2500.0,area_tolerance=1.0,smoothing_area=0.0,forces_only=false)
    isfinite(smoothing_area) && smoothing_area>=0 || error("invalid fold smoothing")
    q=[means(c,p) for (c,p) in zip(countries,plans)]
    g=[zeros(size(v)) for v in q]
    penalty=0.0
    coefficient=6371^2/(2area_scale*max(length(triangles),1))
    width=2smoothing_area/6371^2
    for (k,a,b,d) in triangles
        qa,qb,qd=q[k][:,a],q[k][:,b],q[k][:,d]
        area=dot(qa,cross(qb,qd)) - 2area_tolerance/6371^2
        area<=0 && continue
        smooth=width>0 && area<width
        penalty+=coefficient*(smooth ? area^2/(2width) : area-width/2)
        slope=coefficient*(smooth ? area/width : 1.)
        g[k][:,a].+=slope.*cross(qb,qd)
        g[k][:,b].+=slope.*cross(qd,qa)
        g[k][:,d].+=slope.*cross(qa,qb)
    end
    gradient=forces_only ? [v./sum(p;dims=1) for (v,p) in zip(g,plans)] :
        [(transpose(c.xyz)*v .- sum(q[k].*v;dims=1))./sum(plans[k];dims=1)
         for (k,(c,v)) in enumerate(zip(countries,g))]
    return penalty,gradient
end

function objective(countries, plans, edges, strength, eta; kwargs...)
    base = sum(sum(c.cost .* p) + eta * sum(x -> x > 0 ? x * (log(x)-1) : 0.0, p)
               for (c, p) in zip(countries, plans))
    penalty, _ = penalty_gradient(countries, plans, edges; forces_only=true,kwargs...)
    return base + strength * penalty
end

function metrics(countries, plans, edges)
    q = [means(c, p) for (c, p) in zip(countries, plans)]
    unit = [v ./ sqrt.(sum(abs2, v; dims=1)) for v in q]
    distances = [6371acos(clamp(dot(unit[k][:,j], unit[l][:,t]), -1, 1)) for (k,j,l,t) in edges]
    interior = [d for (d,e) in zip(distances, edges) if e[1] == e[3]]
    seam = [d for (d,e) in zip(distances, edges) if e[1] != e[3]]
    spread = vcat([6371sqrt.(max.(0.0, 1 .- vec(sum(abs2,v; dims=1)))) for v in q]...)
    percentile(v, p) = isempty(v) ? 0.0 : quantile(v, p)
    marginal = maximum(sum(abs.(vec(sum(p; dims=1)) .- c.b)) for (c,p) in zip(countries,plans))
    border_targets = Set{Tuple{Int,Int}}()
    for (k,j,l,t) in edges
        k == l && continue
        push!(border_targets,(k,j)); push!(border_targets,(l,t))
    end
    local_indices = [i for (i,(k,j,l,t)) in enumerate(edges)
                     if k==l && ((k,j) in border_targets || (l,t) in border_targets)]
    local_internal = distances[local_indices]
    rms = [6371sqrt(max(0.0,2-2dot(q[k][:,j],q[l][:,t]))) for (k,j,l,t) in edges]
    cross_rms = [d for (d,e) in zip(rms,edges) if e[1]!=e[3]]
    local_rms = rms[local_indices]
    return (; local_p50=percentile(local_internal,.5),local_p90=percentile(local_internal,.9),
            cross_rms_p50=percentile(cross_rms,.5),cross_rms_p90=percentile(cross_rms,.9),
            cross_rms_all=isempty(cross_rms) ? 0. : sqrt(mean(abs2,cross_rms)),cross_rms_max=percentile(cross_rms,1),
            local_rms_p50=percentile(local_rms,.5),local_rms_p90=percentile(local_rms,.9),
            local_rms_all=isempty(local_rms) ? 0. : sqrt(mean(abs2,local_rms)),local_rms_max=percentile(local_rms,1),
            interior_p50=percentile(interior,.5), interior_p90=percentile(interior,.9),
            interior_max=percentile(interior,1), seam_p50=percentile(seam,.5),
            seam_p90=percentile(seam,.9),seam_max=percentile(seam,1),spread_mean=mean(spread),
            spread_p90=percentile(spread,.9),spread_p99=percentile(spread,.99),spread_max=maximum(spread),marginal_error=marginal,
            target_max_relative=maximum(maximum(abs.(vec(sum(p;dims=1))./c.b .- 1))
                                        for (c,p) in zip(countries,plans)))
end

function export_mapping(path, countries, plans; retained=PCP.CUMULATIVE_WEIGHT)
    0 < retained < 1 || error("retained must be between zero and one")
    output = DataFrame(x=Int[], y=Int[], id=UInt64[], code=Int[], weight=Float64[], weight_mean=Float64[])
    population = Dict{UInt64,Float64}()
    for c in countries, row in eachrow(c.source)
        population[row.id] = get(population,row.id,0.0) + row.value
    end
    for (c, p) in zip(countries, plans)
        totals = vec(sum(p; dims=1))
        for i in axes(p,1)
            weights = p[i,:] ./ c.a[i]
            order=sortperm(weights;rev=true)
            count=searchsortedfirst(cumsum(weights[order]),retained)
            for j in order[1:count]
                push!(output, (c.target.x[j], c.target.y[j], c.source.id[i], c.code,
                               weights[j]*c.source.value[i]/population[c.source.id[i]], p[i,j]/totals[j]))
            end
        end
    end
    # Full-plan weight_mean values are not renormalized after sparse extraction.
    Arrow.write(path, output)
end

function run_case(countries, backend, outdir; strength=0.001, eta=0.002, outer_steps=3,
                  borders=Set([(276,616)]), border_share=nothing, scale_km=300.0,
                  interior_limit=Inf, spread_limit=1.05, form=:mean, saturating=true,
                  initial_plans=nothing, export_arrow=true, preserve_displacements=false,
                  fold_strength=0.0, fold_smoothing=0.0, matrix_free=false, internal_scale=1.0, inner_tolerance=1e-5,
                  proximal=0.0,anneal=false,accelerate=false,internal_form=form,starting_plans=nothing,
                  border_scale=1.0,coordinate=false,border_factors=Dict())
    proximal>=0 || error("proximal weight must be nonnegative")
    all(x->isfinite(x)&&x>=0,(internal_scale,border_scale)) || error("invalid edge scale")
    all(x->isfinite(x)&&x>=0,values(border_factors)) || error("invalid border factors")
    matrix_free && proximal>0 && error("proximal costs require the dense experimental path")
    ispath(outdir) && error("refusing to overwrite $outdir")
    mkpath(outdir)
    edges = graph(countries; borders)
    weights = edge_weights(edges, border_share)
    weights .*= [k==l ? internal_scale : border_scale*get(border_factors,minmax(countries[k].code,countries[l].code),1.)
                 for (k,j,l,t) in edges]
    faces = triangles(countries)
    border_pairs=sort!(collect(borders))
    CSV.write(joinpath(outdir,"borders.csv"),DataFrame(country_a=first.(border_pairs),country_b=last.(border_pairs)))
    factor_pairs=sort!(collect(keys(border_factors)))
    CSV.write(joinpath(outdir,"border-factors.csv"),DataFrame(country_a=first.(factor_pairs),country_b=last.(factor_pairs),
        factor=[border_factors[p] for p in factor_pairs]))
    CSV.write(joinpath(outdir,"settings.csv"), DataFrame(;
        strength=[strength], eta=[eta], scale_km=[scale_km], border_share=[something(border_share,missing)],
        interior_limit=[interior_limit],spread_limit=[spread_limit],form=[string(form)],internal_form=[string(internal_form)],
        saturating=[saturating],preserve_displacements=[preserve_displacements],fold_strength=[fold_strength],fold_smoothing=[fold_smoothing],
        matrix_free=[matrix_free],internal_scale=[internal_scale],border_scale=[border_scale],inner_tolerance=[inner_tolerance],
        proximal=[proximal],anneal=[anneal],accelerate=[accelerate],coordinate=[coordinate],outer_steps=[outer_steps],
        internal_edges=[count(e -> e[1]==e[3],edges)], border_edges=[count(e -> e[1]!=e[3],edges)]))
    println("Case: $(getproperty.(countries,:code)); sources=$(nrow.(getproperty.(countries,:source))); targets=$(nrow.(getproperty.(countries,:target))); edges=$(length(edges))")
    flush(stdout)
    plans = isnothing(initial_plans) ? Matrix{Float64}[] : copy(initial_plans)
    if isnothing(initial_plans)
        for c in countries
            elapsed = @elapsed result = matrix_free ?
                feature_sinkhorn(c,zeros(3,length(c.b)),backend;eta,tolerance=inner_tolerance,anneal,accelerate) :
                sinkhorn(c.cost,c.a,c.b,backend;eta,tolerance=inner_tolerance,anneal,accelerate)
            println("Baseline $(c.code): $(round(elapsed;digits=1)) s, $(result.iterations) dual + $(result.refinement_iterations) primal iterations, residual=$(result.marginal_error)")
            flush(stdout)
            push!(plans, result.plan)
        end
    end
    reference = preserve_displacements ? [means(c,p) for (c,p) in zip(countries,plans)] : nothing
    score_plan(p) = objective(countries,p,edges,strength,eta; weights,scale_km,form,internal_form,saturating,reference) +
                    (fold_strength==0 ? 0.0 : fold_strength*first(fold_penalty_gradient(countries,p,faces;smoothing_area=fold_smoothing,forces_only=true)))
    baseline = metrics(countries, plans, edges)
    export_arrow && export_mapping(joinpath(outdir,"baseline.arrow"), countries, plans)
    checkpoint(joinpath(outdir,"baseline.jls"),plans)
    export_seams(joinpath(outdir,"baseline-seams.csv"),countries,plans,edges)
    rows = [(; iteration=0, updated_country=0, damping=0.0, accepted=true, objective=score_plan(plans), baseline...)]
    CSV.write(joinpath(outdir,"metrics.csv"), DataFrame(rows))
    within_limits(m) = (spread_limit==Inf || (m.spread_mean <= spread_limit*baseline.spread_mean &&
                       m.spread_p90 <= spread_limit*baseline.spread_p90)) &&
                      (interior_limit==Inf || (m.interior_p90 <= interior_limit*baseline.interior_p90 &&
                       m.interior_max <= interior_limit*baseline.interior_max))
    if !isnothing(starting_plans)
        length(starting_plans)==length(countries) || error("seed country count differs")
        for (c,p) in zip(countries,starting_plans)
            size(p)==size(c.cost) && all(x->isfinite(x)&&x>=0,p) || error("invalid seed plan")
            maximum(abs.(vec(sum(p;dims=2))./c.a.-1))<=1e-8 || error("seed source masses differ")
        end
        seed_metrics=metrics(countries,starting_plans,edges)
        seed_metrics.marginal_error<=inner_tolerance && seed_metrics.target_max_relative<=.001 || error("seed target masses differ")
        within_limits(seed_metrics) || error("seed exceeds distortion guards")
        plans=copy(starting_plans)
        CSV.write(joinpath(outdir,"seed-metrics.csv"),DataFrame([(;objective=score_plan(plans),seed_metrics...)]))
    end
    trials = NamedTuple[]
    duals = Any[nothing for c in countries]
    groups=coordinate ? length(countries) : 1
    order=sortperm(length.(getproperty.(countries,:b)))
    accepted_in_sweep=false
    for step in 1:outer_steps*groups
        iteration=cld(step,groups)
        active=order[mod1(step,groups)]
        selected=coordinate ? (active:active) : eachindex(countries)
        updated_country=coordinate ? countries[first(selected)].code : 0
        _, gradient = penalty_gradient(countries, plans, edges; weights,scale_km,form,internal_form,saturating,reference,forces_only=matrix_free)
        gradient = [strength.*g for g in gradient]
        if fold_strength>0
            _,fg=fold_penalty_gradient(countries,plans,faces;smoothing_area=fold_smoothing,forces_only=matrix_free)
            gradient = [g .+ fold_strength.*f for (g,f) in zip(gradient,fg)]
        end
        solutions=map(selected) do k
            c,g=countries[k],gradient[k]
            matrix_free ? feature_sinkhorn(c,g,backend;eta,initial_beta=duals[k],tolerance=inner_tolerance,anneal,accelerate) :
                sinkhorn(proximal==0 ? c.cost .+ g : c.cost .+ g .- proximal.*log.(max.(plans[k],floatmin(Float64))),c.a,c.b,backend;
                         eta=eta+proximal,initial_beta=duals[k],tolerance=inner_tolerance,anneal,accelerate)
        end
        println("Inner $iteration/$updated_country: ",[(countries[k].code,s.iterations,s.refinement_iterations,s.marginal_error)
                                                     for (k,s) in zip(selected,solutions)])
        flush(stdout)
        candidate=copy(plans)
        for (k,s) in zip(selected,solutions)
            duals[k]=s.beta
            candidate[k]=s.plan
        end
        before = score_plan(plans)
        accepted = false
        for damping in (2.0^-k for k in 1:10)
            trial=copy(plans)
            for k in selected
                trial[k]=(1-damping).*plans[k].+damping.*candidate[k]
            end
            score = score_plan(trial)
            m = metrics(countries,trial,edges)
            acceptable = score < before - 1e-10 && within_limits(m)
            push!(trials, (; iteration, updated_country, damping, accepted=acceptable, objective=score, m...))
            if acceptable
                plans = trial
                push!(rows, (; iteration, updated_country, damping, accepted=true, objective=score, m...))
                accepted = true
                break
            end
        end
        if !accepted
            push!(rows, (; iteration, updated_country, damping=0.0, accepted=false, objective=before, metrics(countries,plans,edges)...))
        end
        checkpoint(joinpath(outdir,"candidate.jls"),plans)
        CSV.write(joinpath(outdir,"metrics.csv"),DataFrame(rows))
        CSV.write(joinpath(outdir,"trials.csv"),DataFrame(trials))
        println("Outer $iteration: $(last(rows))")
        flush(stdout)
        accepted_in_sweep |= accepted
        if step%groups==0
            accepted_in_sweep || break
            accepted_in_sweep=false
        end
    end
    export_arrow && export_mapping(joinpath(outdir,"candidate.arrow"), countries, plans)
    checkpoint(joinpath(outdir,"candidate.jls"),plans)
    export_seams(joinpath(outdir,"candidate-seams.csv"),countries,plans,edges)
    return rows
end

end
