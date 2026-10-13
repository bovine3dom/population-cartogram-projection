using Test, Random, LinearAlgebra
include("../examples/continuity/mobile_export.jl")
include("../examples/continuity/mobile/moments.jl")
const ME=MobileExport
const MR=MomentReduction
@testset "Moment-preserving export" begin
    @test size(MR.features(ones(3,8)))==(1,8)
    @test size(MR.features([1. 2. 3.;2. 4. 6.]))==(2,3)
    Random.seed!(71)
    ns,nt=8,9;xyz=randn(3,ns);xyz./=sqrt.(sum(abs2,xyz;dims=1))
    targets=[(x,y,1) for x in 0:2:4 for y in 0:2:4]
    meta=(;ids=UInt64.(1:ns),population=Float64.(1:ns),codes=ones(Int,ns),targets,xyz,
        source_index=Dict(UInt64(s)=>Int32(s) for s in 1:ns),
        target_index=Dict(t=>Int32(i) for (i,t) in enumerate(targets)),labels=Dict(Int32(1)=>"Anchor"))
    matrix=rand(ns,nt);matrix./=sum(matrix;dims=2)
    w=[matrix[s,t] for s in 1:ns for t in 1:nt]
    index=ME.index_rows(UInt32[s for s in 1:ns for t in 1:nt],zeros(UInt32,ns*nt),
        [targets[t][1] for s in 1:ns for t in 1:nt],[targets[t][2] for s in 1:ns for t in 1:nt],ones(Int,ns*nt),w,meta)
    data=(;meta,index,weight=w);reference=ME.reference_stats(data)
    result=MR.reduce_block(data,Int32.(eachindex(w)),w,reference.target_mass)
    @test !result.skipped
    @test length(result.rows)<=result.constraints+1
    @test length(result.rows)<length(w)
    @test result.residual<=1e-6
    summary=ME.evaluate(data,result.rows,reference;weights=result.weights)
    @test summary.source_sum_error<1e-8
    @test summary.target_mass_error_max<1e-6
    @test summary.forward_max<1e-6
    @test summary.inverse_km_max<.001
    anchor=index.source_rows[index.source_ptr[1]]
    @test anchor in result.rows
    @test result.weights[findfirst(==(anchor),result.rows)]>=.5w[anchor]-1e-10
    @test_throws ErrorException MR.reduce_block(data,Int32[],Float64[],reference.target_mass)
end
