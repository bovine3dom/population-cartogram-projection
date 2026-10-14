using Test,Serialization,Arrow,H3,DataFrames
include("../examples/continuity/experiment.jl")
include("../examples/continuity/sparse_refinement.jl")
include("../examples/continuity/mobile_export.jl")
include("../examples/continuity/native_hierarchy.jl")
const NH=NativeHierarchy
const ME=MobileExport
backends=Any[ContinuityExperiment.KA.CPU()]
if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
    using oneAPI
    push!(backends,oneAPI.oneAPIBackend())
end
for backend in backends
@testset "Native hierarchy: $backend" begin
    support=[Set([1]),Set([2])]
    @test NH.bridge!(support,[.8,.2],2)==2
    @test 2 in support[1]
    kept=NH.retain([1,1,2],[1,2,2],[.9,.01,.09],2,2;fraction=.8)
    @test 1 in kept && 3 in kept
    ids=[H3.API.latLngToCell(H3.Lib.LatLng(0.,x),5) for x in (0.,.1)]
    children=vcat([H3.API.cellToChildren(id,6)[1:2] for id in ids]...)
    meta=(;ids,population=[30.,70.],codes=[24,24],targets=[(0,0,24),(2,0,24)],xyz=NH.xyz(ids),labels=Dict(Int32(1)=>"City"))
    source=Int32[1,1,2,2];target=Int32[1,2,1,2];weight=[.8,.2,.1,.9]
    sp,sr=ME.group_rows(source,2);tp,tr=ME.group_rows(target,2)
    guide=(;meta,index=(;source,target,source_ptr=sp,source_rows=sr,target_ptr=tp,target_rows=tr),weight)
    mktempdir() do dir
        path=joinpath(dir,"native.arrow")
        Arrow.write(path,(;id=children,population=[15.,15.,35.,35.],country_code=fill(24,4)))
        state=NH.prepare(guide,path)
        @test state.a≈[.3,.7]
        projection=NH.project(state,backend)
        @test projection.check.l1<=1e-5
        fit=NH.split_sources(state,projection,backend;etas=(.01,))
        result=NH.pack_part(state,fit)
        @test result.stats.source<1e-10
        @test result.stats.relative<=.001
        @test length(result.part.meta.ids)==4
        @test collect(values(result.part.labels))==["City"]
        @test result.label_fallbacks==0
        inherited=NH.pack_part(state,NH.inherited(state,projection))
        @test inherited.stats.source<1e-10
        @test inherited.stats.relative<=.001
    end
end
end
