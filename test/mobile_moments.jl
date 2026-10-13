using Test, Random, LinearAlgebra
include("../examples/continuity/mobile/reduce.jl")
include("../examples/continuity/mobile/quality.jl")
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
    uneven=merge(data,(;meta=merge(meta,(;population=10.0.^range(-3,3;length=ns)))))
    unequal_reference=ME.reference_stats(uneven)
    unequal=MR.reduce_block(uneven,Int32.(eachindex(w)),w,unequal_reference.target_mass)
    unequal_summary=ME.evaluate(uneven,unequal.rows,unequal_reference;weights=unequal.weights)
    @test unequal_summary.source_sum_error<1e-6
    @test unequal_summary.inverse_km_max<.001
    tiny=merge(data,(;weight=1e-7.*w))
    reduced=MR.reduce_block(tiny,Int32.(eachindex(w)),tiny.weight,reference.target_mass)
    @test length(reduced.rows)<length(w)
    @test reduced.residual<1e-14
    @test sum(reduced.weights)≈sum(tiny.weight) rtol=1e-8
    @test_throws ErrorException MR.reduce_block(data,Int32[],Float64[],reference.target_mass)
    mktempdir() do dir
        ids=[MR.H3.API.latLngToCell(MR.H3.API.LatLng(.4+.01s,.1),5) for s in 1:ns]
        names,fields=MobileQuality.probe_fields(merge(meta,(;ids)))
        noise=fields[findfirst(==("synthetic_noise"),names),:]
        @test all(v->0<=v<1,noise)
        @test length(names)==size(fields,1)==10
        input=joinpath(dir,"input.jls");out=joinpath(dir,"out")
        serialize(input,merge(data,(;meta=merge(meta,(;ids)))))
        reduce_country(input,out;stages=[(8,9)])
        saved=deserialize(joinpath(out,"stage-1.jls"))
        @test saved.summary.rows<length(w)
        @test saved.summary.inverse_km_max<.001
        @test isnothing(reduce_country(input,out;stages=[(8,9)]))
        @test_throws ErrorException reduce_country(input,out;stages=[(4,9)])
        seeded=joinpath(dir,"seeded")
        @test isnothing(reduce_country(input,seeded;stages=[(8,9)],seed=joinpath(out,"stage-1.jls")))
        @test deserialize(joinpath(seeded,"stage-1.jls")).summary.source_sum_error<1e-6
    end
end
