using Test, Arrow, CSV, H3, SHA
include("../examples/continuity/mobile/audit.jl")
include("../examples/continuity/mobile/write.jl")
const MA=MobileAudit
const ME=MA.MobileExport
const MW=MobileWriter
@testset "Independent mobile Arrow audit" begin
    ids=[H3.API.latLngToCell(H3.API.LatLng(.4+.01s,.1),5) for s in 1:3]
    source=repeat(1:3;inner=2);x=repeat([0,2],3);y=zeros(Int,6);code=ones(Int,6)
    lo=UInt32.(ids[source].&0xffffffff);hi=UInt32.(ids[source].>>32)
    pop=[10.,2.,8.][source];labels=Union{Missing,String}[missing,"City",missing,missing,missing,missing]
    w=[.25,.75,.5,.5,.75,.25]
    meta=ME.metadata(lo,hi,x,y,pop,code,labels)
    index=ME.index_rows(lo,hi,x,y,code,w,meta)
    data=(;meta,index,weight=w)
    table=MW.columns([MW.select_part(data,(;rows=Int32.(1:6),weights=w))])
    kept=[2,3,4,5,6]
    cut=(; (name=>getproperty(table,name)[kept] for name in keys(table))...)
    cut.weight[1]=1
    tv=MA.variation(cut,table,meta,MA.stats(cut,meta),MA.stats(table,meta))
    @test tv[1]≈2.5/9.5
    @test 0<tv[2]<tv[1]
    mktempdir() do dir
        input,reference,candidate,density,report=[joinpath(dir,name) for name in ["input.arrow","reference.arrow","candidate.arrow","density.arrow","audit.toml"]]
        Arrow.write(input,table);Arrow.write(reference,table);Arrow.write(candidate,table)
        density_table=(;index_lower=UInt32.(ids.&0xffffffff),index_upper=UInt32.(ids.>>32),
            value=meta.population./H3.API.cellAreaKm2.(ids))
        Arrow.write(density,density_table)
        result=MA.audit(input,reference,candidate,density,report)
        @test result["rows"]==6
        @test result["sources"]==3
        @test result["labels"]==1
        @test result["target_tv_max"]<1e-15
        @test result["source_sum_error"]<1e-7
        @test isfile(report)
        @test result["sha256"]["transport"]==open(bytes2hex∘sha256,candidate)
        @test result["sha256"]["density"]==open(bytes2hex∘sha256,density)
        query_report=joinpath(dir,"audit.queries.csv")
        @test result["query_report_sha256"]==open(bytes2hex∘sha256,query_report)
        @test all(r->r.absolute_max==0,CSV.File(query_report))
        Arrow.write(candidate,merge(table,(;index_lower=Arrow.DictEncode(table.index_lower),
            population=Arrow.DictEncode(table.population),label=Arrow.DictEncode(table.label))))
        @test MA.audit(input,reference,candidate,density,report)["source_sum_error"]<1e-7
        Arrow.write(candidate,merge(table,(;weight=Float64.(table.weight))))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
        changed=copy(table.label);changed[1],changed[2]=changed[2],changed[1]
        Arrow.write(candidate,merge(table,(;label=changed)))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
        Arrow.write(candidate,table)
        Arrow.write(density,merge(density_table,(;index_lower=Int64.(density_table.index_lower))))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
        Arrow.write(density,merge(density_table,(;value=2density_table.value)))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
    end
end
