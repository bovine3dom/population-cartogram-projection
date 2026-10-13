using Test, Serialization
include(joinpath(@__DIR__,"..","examples","continuity","experiment.jl"))
const CE=ContinuityExperiment
using .ContinuityExperiment: DataFrame

function fixture()
    source=DataFrame(id=UInt64.(1:4),x=[-2.,-1.,1.,2.],y=[49.,51.,50.,52.],value=[1.,2.,3.,4.])
    target=DataFrame(x=[0,2,4,0,2,4],y=[0,0,0,2,2,2])
    problem=CE.PCP._prepare_problem(target,source)
    xyz=hcat([[cosd(y)*cosd(x),cosd(y)*sind(x),sind(y)] for (x,y) in zip(source.x,source.y)]...)
    return (;source,target,problem,xyz,cost=CE.GeometryCost(problem),a=source.value./sum(source.value),b=fill(1/6,6),code=1)
end

backends=Any[CE.KA.CPU()]
if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
    using oneAPI
    @test oneAPI.functional()
    push!(backends,oneAPI.oneAPIBackend())
end
for backend in backends
    @testset "Compact plans: $backend" begin
        c=fixture();eta=.02
        force=zeros(3,length(c.b))
        @test_throws ErrorException CE.compact_sinkhorn(c,force,nothing,backend;eta=0.)
        @test_throws ErrorException CE.compact_sinkhorn(c,force,nothing,backend;proximal=.1)
        @test_throws ErrorException CE.compact_sinkhorn(c,zeros(3,1),nothing,backend)
        @test_throws CE.CompactConvergenceError CE.compact_sinkhorn(c,force,nothing,backend;maxiters=1)
        dense=CE.sinkhorn(Matrix(c.cost),c.a,c.b,backend;eta,tolerance=1e-6,accelerate=true)
        result=CE.compact_sinkhorn(c,force,nothing,backend;eta,tolerance=1e-6,block_pairs=12,max_pairs=10)
        p=result.plan
        workspace=CE.compact_workspace(c,force,nothing,backend;max_pairs=16)
        cached=workspace.cost_device
        fill!(cached,NaN32);CE.KA.synchronize(backend);workspace.dirty[]=true
        reused=CE.compact_sinkhorn(c,force,nothing,backend;eta,tolerance=1e-6,workspace,max_pairs=16)
        @test Matrix(reused.plan) ≈ Matrix(p) atol=2e-6
        @test workspace.cost_device===cached && !workspace.dirty[]
        @test_throws ErrorException CE.compact_sinkhorn(c,force.+1,nothing,backend;workspace,max_pairs=16)
        implicit=CE.compact_sinkhorn(c,force,nothing,backend;eta,tolerance=1e-6,cache_bytes=0,max_pairs=10).plan
        @test Matrix(implicit) ≈ Matrix(p) atol=2e-6
        @test Matrix(p) ≈ dense.plan atol=2e-6
        @test vec(sum(Matrix(p);dims=2)) ≈ c.a atol=1e-12
        @test vec(sum(p;dims=1)) ≈ c.b atol=1e-5
        @test (@inferred CE.means(c,p)) ≈ CE.means(c,Matrix(p)) atol=1e-12
        @test (@inferred CE.transport_score(c,p,eta,nothing)) ≈ CE.transport_score(c,Matrix(p),eta,nothing) atol=1e-12
        @test p.stats.base ≈ CE.dot(c.cost,Matrix(p)) atol=1e-12
        @test p.stats.entropy ≈ sum(x->x>0 ? x*(log(x)-1) : 0.,Matrix(p)) atol=1e-12
        perturbed=deepcopy(p)
        perturbed.data.v[:,end].+=.01sin.(1:length(c.b))
        CE.compact_stats!(perturbed,c;normalize=true)
        before=Matrix(perturbed)
        cache=CE.KA.zeros(backend,Float32,size(p))
        polished=CE.compact_polish(perturbed,c,backend,cache;tolerance=1e-6,max_pairs=16,block_pairs=16)
        @test !isnothing(polished)
        @test polished.converged
        @test Matrix(polished.plan) ≈ Matrix(p) atol=2e-6
        @test Matrix(perturbed)==before
        @test length(polished.plan.data.rho)==length(p.data.rho)
        @test vec(sum(Matrix(polished.plan);dims=2)) ≈ c.a atol=1e-12
        @test isnothing(CE.compact_polish(perturbed,c,backend,cache;maxiters=1))
        @test isnothing(CE.sparse_primal_arrays(perturbed,c;budget=0))
        sparse=CE.sparse_primal_arrays(perturbed,c;budget=10000,tolerance=1e-6,block_pairs=16)
        @test sparse.bytes<=10000
        @test length(sparse.rows.values)==length(sparse.columns.values)
        @test isnothing(CE.sparse_primal_arrays(perturbed,c;budget=sparse.bytes-1,tolerance=1e-6))
        for (layout,reference) in ((sparse.rows,before),(sparse.columns,transpose(before)))
            weights=zeros(size(reference))
            for i in axes(weights,1),entry in layout.ptr[i]:layout.ptr[i+1]-1
                weights[i,layout.indices[entry]]=layout.values[entry]
            end
            @test weights ≈ reference rtol=1e-6
        end
        emptyrow=deepcopy(perturbed);emptyrow.data.u[1,end]-=1000
        @test isnothing(CE.sparse_primal_arrays(emptyrow,c;budget=10000))
        refined=CE.compact_sparse_polish(perturbed,c,backend;budget=10000,tolerance=1e-6,max_pairs=16,block_pairs=16)
        @test !isnothing(refined)
        @test refined.converged
        @test Matrix(refined.plan) ≈ Matrix(p) atol=2e-6
        @test Matrix(perturbed)==before
        @test vec(sum(Matrix(refined.plan);dims=2)) ≈ c.a atol=1e-12
        shifted=deepcopy(p);shifted.data.v[:,end].+=10 .* c.target.x
        CE.compact_stats!(shifted,c;normalize=true)
        partial=CE.compact_sparse_polish(shifted,c,backend;budget=10000,maxiters=20,tolerance=1e-8)
        @test !isnothing(partial)
        @test !partial.converged
        @test partial.marginal_error<sum(abs.(shifted.stats.target.-c.b))
        @test length(partial.plan.data.rho)==length(shifted.data.rho)
        posed=merge(c,(;problem=CE.pose_problem(c,90)))
        pose_plan=CE.compact_sinkhorn(posed,force,nothing,backend;eta,tolerance=1e-6).plan
        pose_reference=CE.sinkhorn(CE.pose_cost(c,90),c.a,c.b,backend;eta,tolerance=1e-6).plan
        @test Matrix(pose_plan) ≈ pose_reference atol=2e-6
        @test pose_plan.stats.base ≈ CE.dot(c.cost,Matrix(pose_plan)) atol=1e-12
        returned=CE.compact_sinkhorn(c,force,pose_plan,backend;eta,proximal=.1,tolerance=1e-6).plan
        return_cost=Matrix(c.cost)-.1log.(max.(Matrix(pose_plan),floatmin(Float64)))
        return_reference=CE.sinkhorn(return_cost,c.a,c.b,backend;eta=eta+.1,tolerance=1e-6).plan
        @test Matrix(returned) ≈ return_reference atol=2e-6
        for iteration in 1:3
            force=[.2sin(i+j+iteration) for i in 1:3,j in 1:6]
            prior=Matrix(p)
            cost=Matrix(c.cost)+transpose(c.xyz)*force-.1log.(max.(prior,floatmin(Float64)))
            reference=CE.sinkhorn(cost,c.a,c.b,backend;eta=eta+.1,tolerance=1e-6,accelerate=true)
            candidate=CE.compact_sinkhorn(c,force,p,backend;eta,proximal=.1,tolerance=1e-6,block_pairs=12,max_pairs=10).plan
            @test Matrix(candidate) ≈ reference.plan atol=2e-6
            if iteration==1
                stages=Float64[]
                retried=CE.compact_solve(c,force,p,backend;eta,proximal=.1,tolerance=1e-6,retry_after=1,
                    stage_callback=(factor,result)->push!(stages,factor))
                @test stages==[16.,8.,4.,2.,1.]
                @test Matrix(retried.plan) ≈ reference.plan atol=2e-6
                @test length(retried.plan.data.rho)==length(p.data.rho)+1
            end
            if iteration==3
                implicit=CE.compact_sinkhorn(c,force,p,backend;eta,proximal=.1,tolerance=1e-6,cache_bytes=0,max_pairs=10).plan
                @test Matrix(implicit) ≈ Matrix(candidate) atol=2e-6
            end
            mixed=CE.mix_plans(p,candidate,.25)
            CE.compact_stats!(mixed,c;block_pairs=12)
            @test Matrix(mixed) ≈ .75prior+.25Matrix(candidate) atol=1e-12
            @test vec(sum(Matrix(mixed);dims=2)) ≈ c.a atol=1e-12
            p=mixed
        end
        mktempdir() do dir
            other=merge(c,(;code=2,target=DataFrame(x=c.target.x.+6,y=c.target.y),xyz=c.xyz[:,end:-1:1]))
            countries=[c,other]
            kwargs=(;borders=Set([(1,2)]),eta=.02,strength=10.,scale_km=900.,border_share=.25,
                form=:distribution,saturating=false,proximal=.1,coordinate=true,outer_steps=2,
                spread_limit=Inf,interior_limit=Inf,inner_tolerance=1e-6,accelerate=true,export_arrow=false)
            dense_rows=CE.run_case(countries,backend,joinpath(dir,"dense");kwargs...)
            compact_rows=CE.run_case(countries,backend,joinpath(dir,"compact");compact=true,kwargs...)
            @test last(compact_rows).objective ≈ last(dense_rows).objective atol=2e-5
            @test all(diff(getproperty.(compact_rows,:objective)).<=1e-10)
            dense_plans=deserialize(joinpath(dir,"dense","candidate.jls"))
            compact_plans=deserialize(joinpath(dir,"compact","candidate.jls"))
            stage=deserialize(joinpath(dir,"compact","inner-stage.jls"))
            @test (stage.step,stage.country,stage.factor)==(4,2,1.)
            @test stage.result.marginal_error<=1e-6
            @test all(isfinite,stage.result.beta)
            @test all(isapprox(Matrix(a),b;atol=2e-5) for (a,b) in zip(compact_plans,dense_plans))
            baseline=deserialize(joinpath(dir,"compact","baseline.jls"))
            CE.run_case(countries,backend,joinpath(dir,"first-pass");compact=true,initial_plans=baseline,
                merge(kwargs,(;outer_steps=1))...)
            firstpass=deserialize(joinpath(dir,"first-pass","candidate.jls"))
            partial=copy(baseline);partial[1]=firstpass[1]
            resumed=CE.run_case(countries,backend,joinpath(dir,"resumed");compact=true,initial_plans=baseline,
                starting_plans=partial,start_step=2,initial_duals=CE.warm_beta.(partial),kwargs...)
            @test isfile(joinpath(dir,"resumed","initial-duals.jls"))
            @test resumed[2].iteration==1 && resumed[2].updated_country==2
            resumed_plans=deserialize(joinpath(dir,"resumed","candidate.jls"))
            @test all(isapprox(Matrix(a),Matrix(b);atol=2e-5) for (a,b) in zip(resumed_plans,compact_plans))
            @test_throws ErrorException CE.run_case(countries,backend,joinpath(dir,"invalid-start");start_step=0)
            @test_throws ErrorException CE.run_case(countries,backend,joinpath(dir,"no-seed");start_step=2)
            for invalid in ([],[nothing,zeros(1)],[nothing,fill(NaN,length(other.b))])
                @test_throws ErrorException CE.run_case(countries,backend,joinpath(dir,"bad-dual");initial_duals=invalid)
            end
            path=joinpath(dir,"plan.jls")
            serialize(path,p)
            q=deserialize(path)
            @test Matrix(q)==Matrix(p)
            @test CE.means(c,q)==CE.means(c,p)
            updated=CE.append_plan(c,q,force,eta+.1,.1,zeros(length(c.a)),zeros(length(c.b)))
            @test length(updated.problems)==length(q.problems)
            @test updated.data.base_id[end]==q.data.base_id[end]
        end
    end
end
