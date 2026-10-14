using Test
include("../examples/continuity/sharpness.jl")
using .ContinuitySharpness
@testset "Source sharpness diagnostics" begin
    d=ContinuitySharpness.distribution([.5,.5],[(0,0),(2,0)])
    @test d.cells==2
    @test d.counts==(2,2)
    @test d.effective_entropy≈2
    @test d.effective_simpson≈2
    @test d.spread≈1
    @test d.top1==.5
    d=ContinuitySharpness.distribution([.5,.5,0.],[(1,1),(1,1),(99,99)])
    @test d.cells==1
    @test d.counts==(1,1)
    @test d.spread==0
    @test d.effective_simpson==1
    d=ContinuitySharpness.distribution([9.96,.04],[(0,0),(1,0)])
    @test d.mass==10
    @test d.counts==(1,2)
    @test d.top1≈.996
    @test_throws ErrorException ContinuitySharpness.distribution([0.],[(0,0)])
    @test_throws ErrorException ContinuitySharpness.distribution([-1.,2.],[(0,0),(1,0)])
    @test_throws ErrorException ContinuitySharpness.distribution([NaN],[(0,0)])
    @test_throws ErrorException ContinuitySharpness.distribution([1.],[(Inf,0)])
    @test_throws ErrorException ContinuitySharpness.distribution([1.],[(0,0)];retained=(0.,))
    data=(meta=(ids=UInt64[1,2],codes=[7,7],population=[3.,1.],targets=[(0,0,7),(2,0,7)]),
        index=(source=[1,1,2],target=[1,2,2],source_ptr=[1,3,4],source_rows=[1,2,3]),weight=[.5,.5,1.])
    rows=ContinuitySharpness.source_rows(data)
    @test rows[1].n995==2
    @test rows[2].n995==1
    @test rows[1].quota==1.5
    @test rows[1].capacity_quota≈3/2.5
    s=ContinuitySharpness.summarize(rows,2)
    @test s.ratio995==1.5
    @test s.old_budget==8
    @test s.population_weighted_spread==.75
    c=(code=7,a=[.75,.25],b=[.5,.5],target=(x=[0.,2.],y=[0.,0.]),
        source=(id=UInt64[1,2],value=[3.,1.]))
    p=[.375 .375;0 .25]
    planned=ContinuitySharpness.plan_rows(c,p,(p,r)->p[r,:];block_pairs=2)
    @test [r.n995 for r in planned]==[2,1]
    @test [r.source_mass for r in planned]==[1,1]
    @test planned[1].spread==1
    support=ContinuitySharpness.retained_support(p,(p,r)->p[r,:];block_pairs=2)
    @test support.counts==[r.n995 for r in planned]
    @test support.rows==3
    @test ContinuitySharpness.retained_support([1. 0.;.2 .8],(p,r)->p[r,:];retained=1.).counts==[1,2]
    @test_throws ErrorException ContinuitySharpness.retained_support(p,(p,r)->p[r,:];retained=0.)
    @test_throws ErrorException ContinuitySharpness.retained_support(zeros(1,2),(p,r)->p[r,:])
    @test_throws ErrorException ContinuitySharpness.plan_rows(c,p,(p,r)->p[r,:];block_pairs=0)
end
