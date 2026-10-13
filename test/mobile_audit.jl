using Test, Arrow, H3
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
        @test result["source_sum_error"]<1e-7
        @test isfile(report)
        Arrow.write(candidate,merge(table,(;weight=Float64.(table.weight))))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
        changed=copy(table.label);changed[1],changed[2]=changed[2],changed[1]
        Arrow.write(candidate,merge(table,(;label=changed)))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
        Arrow.write(candidate,table)
        Arrow.write(density,merge(density_table,(;value=2density_table.value)))
        @test_throws ErrorException MA.audit(input,reference,candidate,density,report)
    end
end
