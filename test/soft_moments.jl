using Test,H3
include("../examples/continuity/mobile/soft_moments.jl")
const SM=SoftMomentPacking
@testset "Bounded moment packing" begin
    @test SM.anchor_kept(1-1e-11,1.)
    @test !SM.anchor_kept(1-1e-8,1.)
    @test !SM.anchor_kept(0.,1e-30)
    ids=[H3.API.latLngToCell(H3.Lib.LatLng(.01i,.013i),6) for i in 1:6]
    xyz=hcat([[cos(g.lat)*cos(g.lng),cos(g.lat)*sin(g.lng),sin(g.lat)] for g in H3.API.cellToLatLng.(ids)]...)
    population=[10.,20.,30.,40.,50.,60.];a=population/sum(population)
    source=Int32[i for i in 1:6 for j in 1:4];target=Int32[j for i in 1:6 for j in 1:4]
    meta=(;ids,population,codes=fill(24,6),targets=[(0,0,24),(0,2,24),(2,0,24),(2,2,24)],xyz,labels=Dict(Int32(2)=>"City"))
    part=(;meta,source,target,weights=a[source]./4,labels=Dict(6=>"City"))
    result=SM.pack_country(part;target_retained=0.,tolerance=.1)
    @test result.report.failed_blocks==0
    @test result.report.source_sum_error<1e-10
    @test result.report.target_mass_error_max<1e-7
    @test result.report.density_relative_error<1e-6
    @test result.report.inverse_km_max<=.001
    @test result.report.forward_coarse_max<=sqrt(2)*.1+1e-6
    @test length(result.part.weights)<=length(part.weights)
    @test length(result.queries)==10
    @test collect(values(result.part.labels))==["City"]
    city=only(keys(result.part.labels))
    @test result.part.source[city]==source[6]&&result.part.target[city]==target[6]
    @test all(first(result.part.source[result.part.target.==j])==1 for j in 1:4)
    exact=SM.pack_country(part;target_retained=1.,tolerance=0.)
    @test exact.report.target_tv_max<1e-7
    @test exact.report.forward_max<1e-7
    @test size(SM.features([1. nextfloat(1.); 1. 1.]),1)<=2
    small=merge(part,(;meta=merge(meta,(;ids=ids[1:2],population=population[1:2],codes=[24,24],xyz=xyz[:,1:2])),
        source=source[1:8],target=target[1:8],weights=repeat([1/3,2/3];inner=4)./4))
    small_result=SM.pack_country(small;target_retained=0.)
    @test small_result.report.failed_blocks==0
    @test small_result.part.weights≈small.weights
    @test_throws ErrorException SM.pack_country(part;deadline=time()-1)
    @test_throws ErrorException SM.pack_country(part;target_retained=1.1)
    @test_throws ErrorException SM.pack_country(part;tolerance=-1.)
    @test_throws ErrorException SM.pack_country(merge(part,(;weights=part.weights.*2)))
end
