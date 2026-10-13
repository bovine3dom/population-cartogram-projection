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
    floors=ME.target_floor_rows(data,.5)
    protected=MR.reduce_block(data,Int32.(eachindex(w)),w,reference.target_mass;floors)
    protected_summary=ME.evaluate(data,protected.rows,reference;weights=protected.weights)
    @test protected_summary.target_tv_max<=.5+1e-6
    @test all(!floors[r] || protected.weights[k]>=w[r]-1e-8 for (k,r) in enumerate(protected.rows))
    @test all(r->r in protected.rows,findall(floors))
    @test_throws ErrorException MR.reduce_block(data,Int32.(eachindex(w)),w,reference.target_mass;floors=[true])
    sparse_floors=ME.target_floor_rows(data,.1)
    residual=MR.reduce_block(data,Int32.(eachindex(w)),w,reference.target_mass;floors=sparse_floors,fixed_floors=true)
    @test length(residual.rows)<length(w)
    residual_summary=ME.evaluate(data,residual.rows,reference;weights=residual.weights)
    @test residual_summary.source_sum_error<1e-8
    @test residual_summary.forward_max<1e-6
    @test residual_summary.inverse_km_max<.001
    @test residual_summary.target_tv_max<=.9+1e-6
    @test all(r->r in residual.rows,findall(sparse_floors))
    @test all(!sparse_floors[r] || residual.weights[k]>=w[r]-1e-8 for (k,r) in enumerate(residual.rows))
    @test residual.weights[findfirst(==(anchor),residual.rows)]>=.5w[anchor]-1e-10
    fixed=MR.reduce_block(data,Int32.(eachindex(w)),w,reference.target_mass;floors=trues(length(w)),fixed_floors=true)
    @test fixed.weights==w
    @test fixed.rows==eachindex(w)
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
        worker=BoundedReduction.Worker(dir)
        try
            remote=BoundedReduction.reduce_block!(worker,data,Int32.(eachindex(w)),w,reference.target_mass;max_inline=0,limit=60.)
            @test remote.rows==result.rows
            @test remote.weights≈result.weights
            remote_fixed=BoundedReduction.reduce_block!(worker,data,Int32.(eachindex(w)),w,reference.target_mass;
                max_inline=0,limit=60.,floors=sparse_floors,fixed_floors=true)
            @test remote_fixed.rows==residual.rows
            @test remote_fixed.weights≈residual.weights
            @test_throws ErrorException BoundedReduction.execute!(worker,(;f=error,args=("expected failure",),kwargs=(;));seconds=10.)
            @test BoundedReduction.execute!(worker,(;f=identity,args=(42,),kwargs=(;));seconds=10.)==42
            @test_throws ErrorException BoundedReduction.execute!(worker,(;f=sleep,args=(10.,),kwargs=(;));seconds=.05)
            @test isnothing(worker.process)
            @test BoundedReduction.execute!(worker,(;f=identity,args=(43,),kwargs=(;));seconds=60.)==43
        finally
            BoundedReduction.stop!(worker)
        end
        @test isnothing(worker.process)
        @test read(worker.program)==BoundedReduction.CODE["bounded.jl"]
        write(worker.program,"changed")
        @test_throws ErrorException BoundedReduction.Worker(dir)
        checkpoint=joinpath(dir,"working.jls")
        checked_checkpoint(checkpoint,data,result.rows,result.weights,reference;complete=false)
        @test !deserialize(checkpoint).complete
    end
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
        protected_out=joinpath(dir,"protected")
        @test isnothing(reduce_country(input,protected_out;stages=[(8,9)],target_retained=.7))
        @test deserialize(joinpath(protected_out,"stage-1.jls")).summary.target_tv_max<=.3+1e-6
        fixed_out=joinpath(dir,"fixed")
        @test isnothing(reduce_country(input,fixed_out;stages=[(8,9)],target_retained=.7,fixed_floors=true))
        @test deserialize(joinpath(fixed_out,"stage-1.jls")).summary.target_tv_max<=.3+1e-6
        @test deserialize(joinpath(fixed_out,"config.jls")).fixed_floors
        shifted_out=joinpath(dir,"shifted")
        @test isnothing(reduce_country(input,shifted_out;stages=[(4,4),(8,9)],target_retained=.7,
            fixed_floors=true,block_shift=(2,-2)))
        shifted=deserialize(joinpath(shifted_out,"stage-2.jls"))
        @test shifted.summary.target_tv_max<=.3+1e-6
        @test shifted.summary.source_sum_error<1e-6
        @test deserialize(joinpath(shifted_out,"config.jls")).block_shift==(2,-2)
        @test_throws ErrorException reduce_country(input,shifted_out;stages=[(4,4),(8,9)],target_retained=.7,
            fixed_floors=true,block_shift=(0,0))
        latitude_out=joinpath(dir,"latitude")
        @test isnothing(reduce_country(input,latitude_out;stages=[(4,4),(8,9)],target_retained=.7,
            fixed_floors=true,block_order=:latitude))
        latitude=deserialize(joinpath(latitude_out,"stage-2.jls"))
        @test latitude.summary.source_sum_error<1e-6
        @test latitude.summary.target_tv_max<=.3+1e-6
        @test deserialize(joinpath(latitude_out,"config.jls")).block_order==:latitude
        @test_throws ErrorException reduce_country(input,joinpath(dir,"bad_order");block_order=:unknown)
        @test_throws ErrorException reduce_country(input,fixed_out;stages=[(8,9)],target_retained=.7)
        @test_throws ErrorException reduce_country(input,joinpath(dir,"bad_seed");stages=[(8,9)],
            seed=joinpath(out,"stage-1.jls"),target_retained=1.)
    end
end
