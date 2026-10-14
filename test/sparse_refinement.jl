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
    end
end
