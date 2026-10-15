using Test
include("../examples/continuity/native_quality.jl")
@testset "Native quality metrics" begin
    a=(;code=1,target=DataFrame(x=[0,2],y=[0,0]),xyz=[1. 1.; 0. .01; 0. 0.])
    b=(;code=2,target=DataFrame(x=[4],y=[0]),xyz=reshape([1.,.02,0.],3,1))
    @test length(edges([a,b],Set{Tuple{Int,Int}}()))==1
    @test length(edges([a,b],Set([(1,2)])))==2
    stats=geometry([a,b],Set([(1,2)]))
    @test stats.cross_mean_rms_km≈63.71
    @test stats.internal_mean_rms_km≈63.71
    shared=merge(b,(;target=DataFrame(x=[2],y=[0])))
    @test isempty(edges([a,shared],Set([(1,2)])))
    part=(;meta=(;ids=[1],targets=[(-1,-1,1),(-1,1,1),(1,-1,1),(1,1,1)],xyz=reshape([1.,0.,0.],3,1)),
        source=fill(1,4),target=collect(1:4),weights=fill(.25,4))
    result=part_stats(part,2)
    @test result.ratio995==4
    @test result.low_population_sources==0
    small=merge(part,(;meta=(;ids=[1,2],targets=[(0,0,1)],xyz=repeat([1.,0.,0.],1,2)),
        source=[1,2],target=[1,1],weights=[.01,.99]))
    @test part_stats(small,1).low_population_ratio995==1
    @test result.spatial_rms_coarse≈sqrt(1/8)
    @test result.q≈repeat([1.,0.,0.],1,4)
end
