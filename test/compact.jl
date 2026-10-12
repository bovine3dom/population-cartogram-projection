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
        @test Matrix(polished.plan) ≈ Matrix(p) atol=2e-6
        @test Matrix(perturbed)==before
        @test length(polished.plan.data.rho)==length(p.data.rho)
        @test vec(sum(Matrix(polished.plan);dims=2)) ≈ c.a atol=1e-12
        @test isnothing(CE.compact_polish(perturbed,c,backend,cache;maxiters=1))
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
                retried=CE.compact_solve(c,force,p,backend;eta,proximal=.1,tolerance=1e-6,retry_after=1)
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
            @test all(isapprox(Matrix(a),b;atol=2e-5) for (a,b) in zip(compact_plans,dense_plans))
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
