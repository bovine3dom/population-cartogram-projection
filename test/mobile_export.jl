using Test
include("../examples/continuity/mobile_export.jl")
const ME=MobileExport
@testset "Mobile export selection" begin
    meta=(;source_index=Dict(UInt64(1)=>Int32(1),UInt64(2)=>Int32(2)),
        target_index=Dict((0,0,1)=>Int32(1),(2,0,1)=>Int32(2)),
        ids=UInt64[1,2],population=[10.,1.],codes=[1,1],targets=[(0,0,1),(2,0,1)],
        xyz=[1. cos(.1);0. sin(.1);0. 0.],labels=Dict(Int32(2)=>"Test city"))
    w=[.4,.6,.95,.05]
    index=ME.index_rows(UInt32[1,1,2,2],zeros(UInt32,4),[0,2,0,2],zeros(Int,4),ones(Int,4),w,meta)
    data=(;meta,index,weight=w)
    @test index.source_rows==[2,1,3,4]
    @test index.target_rows==[1,3,2,4]
    @test ME.select_rows(data)==[1,2,3]
    @test ME.select_rows(data;target_retained=.99)==[1,2,3]
    @test ME.select_rows(data;source_retained=1.)==[1,2,3,4]
    reference=ME.reference_stats(data)
    full=ME.evaluate(data,Int32[1,2,3,4],reference)
    @test full.population_retained≈1
    @test full.inverse_km_max<1e-9
    @test full.forward_max<1e-12
    @test full.target_mass_error_max<1e-12
    @test full.target_tv_max<1e-12
    reduced=ME.evaluate(data,ME.select_rows(data),reference)
    @test reduced.rows==3
    @test reduced.population_retained≈10.95/11
    @test reduced.target_mass_error_max≈.05/4.95
    @test 0<reduced.target_tv_max<1
    @test_throws ErrorException ME.evaluate(data,Int32[1,2],reference)
    @test_throws ErrorException ME.select_rows(data;source_retained=1.1)
    @test_throws ErrorException ME.select_rows(data;source_top=-1)
    @test_throws ErrorException ME.group_rows(Int32[1],2)
end
