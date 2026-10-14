using Test
include("../examples/continuity/experiment.jl")
include("../examples/continuity/sparse_refinement.jl")
const CE=ContinuityExperiment
const SR=SparseRefinement
backends=Any[CE.KA.CPU()]
if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
    using oneAPI
    push!(backends,oneAPI.oneAPIBackend())
end
for backend in backends
    @testset "Sparse fixed graph: $backend" begin
        c=[.1 .4 .8; .5 .2 .3; .9 .6 .1; .2 .7 .4]
        a=[.1,.2,.3,.4];b=[.2,.3,.5]
        source=[i for i in 1:4 for j in 1:3];target=[j for i in 1:4 for j in 1:3]
        g=SR.graph(4,3,source,target,[c[i,j] for (i,j) in zip(source,target)])
        result=SR.solve(g,a,b,backend;eta=.05)
        dense=CE.sinkhorn(c,a,b,backend;eta=.05,tolerance=1e-6,accelerate=true)
        @test result.error.source<1e-10
        @test result.error.l1<=1e-6 && result.error.relative<=1e-4
        @test result.weights ≈ [dense.plan[i,j] for (i,j) in zip(g.source,g.target)] atol=2e-6
        warm=SR.solve(g,a,b,backend;eta=.025,initial_beta=result.beta)
        @test warm.error.l1<=1e-6
        p=SR.polish(g,fill(1/12,12),a,b,backend;tolerance=1e-6,maxrelative=1e-4)
        @test !isnothing(p)
        @test p.weights ≈ [a[i]*b[j] for (i,j) in zip(g.source,g.target)] atol=1e-7
        @test_throws ErrorException SR.graph(2,2,[1],[1],[1.])
        @test_throws ErrorException SR.graph(1,1,[1],[1],[0.];maxedges=0)
        @test_throws ErrorException SR.graph(Int64(typemax(Int32))+1,1,[1],[1],[0.])
        @test_throws ErrorException SR.graph(1,1,[1,1],[1,1],[0.,1.])
        @test_throws ErrorException SR.solve(g,a,b,backend;eta=0.)
        @test_throws ErrorException SR.solve(g,a,b,backend;eta=.05,tolerance=Inf)
        @test_throws ErrorException SR.solve(g,a,b,backend;eta=.05,deadline=0.)
        @test isnothing(SR.polish(g,fill(1/12,12),a,b,backend;tolerance=1e-6,maxrelative=1e-4,deadline=0.))
        @test_throws ErrorException SR.solve(g,a,b,backend;eta=.05,initial_beta=[NaN,0,0])
        @test_throws ErrorException SR.solve(g,a,b,backend;eta=.05,maxiters=1)
        diagonal=SR.graph(2,2,[1,2],[1,2],[0.,0.])
        exact=SR.solve(diagonal,[.25,.75],[.25,.75],backend;eta=.01)
        @test exact.weights≈[.25,.75]
        @test_throws ErrorException SR.solve(diagonal,[.25,.75],[.5,.5],backend;eta=.01,maxiters=100)
        for (n,m) in ((17,19),(2,33))
            costs=[(i/n-j/m)^2 for i in 1:n,j in 1:m]
            s=[i for i in 1:n for j in 1:m];t=[j for i in 1:n for j in 1:m]
            graph=SR.graph(n,m,s,t,[costs[i,j] for (i,j) in zip(s,t)])
            mass_a=fill(1/n,n);mass_b=fill(1/m,m)
            sparse=SR.solve(graph,mass_a,mass_b,backend;eta=.1)
            full=CE.sinkhorn(costs,mass_a,mass_b,backend;eta=.1,tolerance=1e-6,accelerate=true)
            @test sparse.weights≈[full.plan[i,j] for (i,j) in zip(graph.source,graph.target)] atol=2e-6
        end
        layout=CE.compact_device(backend,(ptr=Int32.(1:21),indices=Int32.(1:20),values=ones(Float32,20)))
        out=CE.PCP._copy_to_backend(backend,fill(-1f0,20))
        scale=CE.PCP._copy_to_backend(backend,ones(Float32,20))
        mass=CE.PCP._copy_to_backend(backend,fill(2f0,20))
        SR.small_scale_reduce!(backend,256)(out,layout,scale,mass,3,10;ndrange=8)
        CE.KA.synchronize(backend)
        expected=fill(-1f0,20);expected[4:10].=2
        @test Array(out)==expected
    end
end
