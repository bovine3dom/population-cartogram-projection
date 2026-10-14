using Test,H3
include("../examples/continuity/target_subdivision.jl")
const TS=TargetSubdivision
@testset "Moment-constrained target subdivision" begin
    points=reshape([-1.,0.,1.],1,3);mass=fill(1/3,3);delta=reshape([-.5,.5],1,2)
    split=TS.split_cell(points,mass,delta)
    @test split.amplitude≈1
    @test vec(sum(split.weights;dims=2))≈mass
    @test vec(sum(split.weights;dims=1))≈[.5,.5]
    @test points*split.weights.*2≈delta atol=1e-7
    tiny=TS.split_cell(points,[1e-14,.5,.5-1e-14],delta./5)
    @test maximum(abs.(vec(sum(tiny.weights;dims=2))./[1e-14,.5,.5-1e-14].-1))<1e-10
    fixed=TS.split_cell(reshape([1.,0.,0.],3,1),[1.],[0. 0.;-.1 .1;0. 0.])
    @test fixed.amplitude<1e-8
    @test_throws ErrorException TS.split_cell(points,mass,ones(1,2))
    @test_throws ErrorException TS.split_cell(points,mass,delta;limit=0.)
    ids=[H3.API.latLngToCell(H3.Lib.LatLng(0.,x),6) for x in (0.,.1)]
    xyz=hcat([[cos(H3.API.cellToLatLng(id).lat)*cos(H3.API.cellToLatLng(id).lng),cos(H3.API.cellToLatLng(id).lat)*sin(H3.API.cellToLatLng(id).lng),sin(H3.API.cellToLatLng(id).lat)] for id in ids]...)
    meta=(;ids,population=[10.,10.],codes=[24,24],targets=[(0,0,24)],xyz,labels=Dict(Int32(1)=>"City"))
    part=(;meta,source=Int32[1,2],target=Int32[1,1],weights=[.5,.5],labels=Dict(1=>"City"))
    result=TS.subdivide(part,2)
    @test result.source_error<1e-10
    @test result.target_error<1e-6
    @test length(result.part.meta.targets)==4
    @test collect(values(result.part.labels))==["City"]
    @test all(isempty(r.reason) for r in result.records)
    @test_throws ErrorException TS.subdivide(part,6)
    @test_throws ErrorException TS.subdivide(part,2;deadline=time()-1)
end
