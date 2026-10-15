using Test,Serialization,Arrow,H3,DataFrames
include("../examples/continuity/experiment.jl")
include("../examples/continuity/sparse_refinement.jl")
include("../examples/continuity/mobile_export.jl")
include("../examples/continuity/native_hierarchy.jl")
include("../examples/continuity/local_balance.jl")
const NH=NativeHierarchy
const ME=MobileExport
backends=Any[ContinuityExperiment.KA.CPU()]
if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
    using oneAPI
    push!(backends,oneAPI.oneAPIBackend())
end
@testset "Local mass correction" begin
    q=[1. 1. 1.; 0. .01 .02; 0. 0. 0.]
    guide=(;meta=(;ids=[1,2,3]),index=(;source_rows=[1,2,3],source_ptr=[1,2,3,4],target=[1,2,3]),weight=ones(3))
    state=(;guide,d=(;b=fill(1/3,3),target=DataFrame(x=[0,2,4],y=zeros(Int,3))),ids=[1,2,3],a=[.5,1/3,1/6],xyz=q,q)
    result=LocalBalance.balance(state)
    @test result.check.l1<1e-8
    @test result.check.source<1e-12
    @test sum(result.weights[(result.source.==1).&(result.target.==3)])<.05
    @test result.virtual_links==0
end
for backend in backends
@testset "Native hierarchy: $backend" begin
    support=[Set([1]),Set([2])]
    @test NH.bridge!(support,[.8,.2],2)==2
    @test 2 in support[1]
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
        local_projection=LocalBalance.balance(state)
        @test local_projection.check.l1<1e-8
        @test local_projection.check.source<1e-12
        @test local_projection.virtual_links==0
        disconnected=merge(state,(;d=merge(state.d,(;target=DataFrame(x=[0,8],y=[0,0])))))
        @test LocalBalance.balance(disconnected).virtual_links==1
        projection=NH.project(state,backend)
        @test projection.check.l1<=1e-5
        fit=NH.split_sources(state,projection,backend;etas=(.01,))
        result=NH.export_part(state,fit)
        positive=findall(>(0),fit.weights)
        @test result.part.weights==fit.weights[positive]
        @test result.part.source==fit.source[positive]
        @test result.part.target==fit.target[positive]
        weights=copy(fit.weights);weights[1]-=1e-12
        tiny=merge(fit,(;source=vcat(fit.source,fit.source[1]),target=vcat(fit.target,fit.target[1]),
            weights=vcat(weights,1e-12)))
        @test NH.export_part(state,tiny).part.weights==tiny.weights
        @test result.stats.source<1e-10
        @test result.stats.relative<=.001
        @test length(result.part.meta.ids)==4
        @test collect(values(result.part.labels))==["City"]
        @test result.label_fallbacks==0
        inherited=NH.export_part(state,NH.inherited(state,projection))
        @test inherited.stats.source<1e-10
        @test inherited.stats.relative<=.001
    end
end
end
