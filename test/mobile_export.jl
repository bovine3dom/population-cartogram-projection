using Test
include("../examples/continuity/mobile_export.jl")
include("../examples/continuity/mobile/write.jl")
include("../examples/continuity/mobile/quality.jl")
const ME=MobileExport
const MW=MobileWriter
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
    @test isnothing(ME.target_floor_rows(data,0.))
    @test ME.target_floor_rows(data,.5)==[true,true,false,false]
    @test ME.target_floor_rows(data,.99)==[true,true,true,false]
    @test_throws ErrorException ME.target_floor_rows(data,1.1)
    reference=ME.reference_stats(data)
    full=ME.evaluate(data,Int32[1,2,3,4],reference)
    @test full.population_retained≈1
    @test full.inverse_km_max<1e-9
    @test full.forward_max<1e-12
    @test full.target_mass_error_max<1e-12
    @test full.target_tv_max<1e-12
    @test ME.evaluate(data,Int32[1,2,3,4],reference;weights=w)==full
    @test_throws ErrorException ME.evaluate(data,Int32[1,2,3,4],reference;weights=[.4,.6,.95,0.])
    @test_throws ErrorException ME.evaluate(data,Int32[1,2,3,4],reference;weights=[1.])
    reduced=ME.evaluate(data,ME.select_rows(data),reference)
    @test reduced.rows==3
    @test reduced.population_retained≈10.95/11
    @test reduced.target_mass_error_max≈.05/4.95
    @test 0<reduced.target_tv_max<1
    @test_throws ErrorException ME.evaluate(data,Int32[1,2],reference)
    @test_throws ErrorException ME.select_rows(data;source_retained=1.1)
    @test_throws ErrorException ME.select_rows(data;source_top=-1)
    @test_throws ErrorException ME.group_rows(Int32[1],2)
    local_data=ME.country_data(data,1)
    @test local_data.original_rows==[2,1,3,4]
    @test local_data.weight==w[local_data.original_rows]
    @test ME.reference_stats(local_data).target_mass≈reference.target_mass
    @test_throws ErrorException ME.country_data(data,9)
    fields=[2. 3.;NaN 1.;NaN NaN]
    probes=MobileQuality.compare_fields(data,Int32[1,2,3,4],w,["full","partial","empty"],fields)
    @test probes[1].absolute_max==0
    @test probes[2].lost==0
    @test ismissing(probes[3].absolute_max)
    lost=MobileQuality.compare_fields(data,Int32[1,2],w[1:2],["full","partial","empty"],fields)
    @test lost[2].lost==2
    @test ismissing(lost[2].absolute_max)
    part=MW.select_part(data,(;rows=Int32[1,2,3,4],weights=w))
    second=merge(part,(;meta=merge(meta,(;population=2meta.population,codes=[2,2],targets=[(0,0,2),(2,0,2)]))))
    table=MW.columns([part,second])
    shifted=merge(part,(;weights=part.weights.*[1.00001,1.00001,.99999,.99999]))
    @test MW.columns([shifted]).weight≈Float32.(w) atol=1e-7
    for tail in (1e-40,1e-100)
        tiny=merge(part,(;source=vcat(part.source,Int32(1)),target=vcat(part.target,Int32(1)),weights=vcat(part.weights,tail)))
        counts=Ref((;dropped_rows=0,ownership_rows=0))
        trimmed=MW.columns([tiny];counts)
        @test trimmed.weight==Float32.(w)
        @test counts[].dropped_rows==1
        @test counts[].ownership_rows==0
        labelled=merge(tiny,(;labels=merge(tiny.labels,Dict(5=>"Required"))))
        tail<1e-50 && @test_throws ErrorException MW.columns([labelled])
    end
    @test eltype(table.x)==Int16
    @test eltype(table.code)==UInt16
    @test eltype(table.weight)==Float32
    @test eltype(table.population)==Float64
    @test all(isapprox(sum(table.weight_mean[table.x.==x]),1;atol=1e-7) for x in [0,2])
    @test count(!ismissing,table.label)==2
    owned=MW.columns([part,second];owners=Dict((0,0)=>2,(2,0)=>2))
    @test length(owned.weight)==10
    @test all(count((owned.x.==x).&(owned.code.==2))>count((owned.x.==x).&(owned.code.==1)) for x in [0,2])
    @test sum(owned.weight)≈sum(table.weight) atol=1e-6
    @test count(!ismissing,owned.label)==2
    @test_throws ErrorException MW.columns([part];owners=Dict((0,0)=>2))
    @test_throws ErrorException MW.select_part(data,(;rows=Int32[1,2,4],weights=w[[1,2,4]]))
    mktempdir() do dir
        path=joinpath(dir,"test.arrow")
        @test MW.write_file(path,[part,second]).rows==8
        saved=ME.Arrow.Table(path)
        @test collect(saved.weight)==table.weight
        @test isequal(collect(saved.label),table.label)
        @test_throws ErrorException MW.write_file(path,[part])
        encoded=joinpath(dir,"dictionary.arrow")
        MW.write_file(encoded,[part,second];dictionary=true)
        decoded=ME.Arrow.Table(encoded)
        @test all(isequal(collect(getproperty(decoded,name)),getproperty(table,name)) for name in keys(table))
        @test eltype(decoded.index_lower)==UInt32
        @test eltype(decoded.population)==Float64
        ordered=joinpath(dir,"ordered.arrow")
        MW.write_file(ordered,[part,second];dictionary=true,source_order=true)
        decoded=ME.Arrow.Table(ordered)
        permutation=[1,2,5,6,3,7,4,8]
        @test all(isequal(collect(getproperty(decoded,k)),table[k][permutation]) for k in keys(table))
        density=(;index_lower=table.index_lower,index_upper=table.index_upper,value=table.population)
        plain=joinpath(dir,"density-plain.arrow");packed=joinpath(dir,"density-packed.arrow")
        ME.Arrow.write(plain,density)
        @test MW.write_density(packed,plain)==filesize(packed)
        decoded=ME.Arrow.Table(packed)
        @test all(collect(getproperty(decoded,k))==density[k] for k in keys(density))
        @test eltype(decoded.index_lower)==UInt32
        @test eltype(decoded.value)==Float64
        @test_throws ErrorException MW.write_density(packed,plain)
        @test_throws ErrorException MW.write_density(joinpath(dir,"bad.arrow"),path)
    end
end
