using Test
include("../examples/continuity/audit_native_packing.jl")
@testset "Binary navigation anchors" begin
    table=(;weight=[.1,.2,.7],x=[0,0,2],y=[0,0,0],index_lower=UInt32[1,2,3],index_upper=UInt32[4,4,4])
    anchors=navigation(table)
    @test length(anchors)==2
    @test anchors[(0,0)]==((UInt64(4)<<32)|1)
    @test anchors[(2,0)]==((UInt64(4)<<32)|3)
    reversed=map(v->reverse(v),table)
    @test navigation(reversed)!=anchors
end
