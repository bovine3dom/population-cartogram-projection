using Test,Arrow,H3,Serialization,CSV,TOML
include("../examples/continuity/native_export.jl")
const NE=NativeExport
@testset "Native binary export" begin
    @test NE.exact_population_column([1.,1949226.])==Float32[1,1949226]
    @test eltype(NE.exact_population_column([1.,1949226.]))==Float32
    @test eltype(NE.exact_population_column([16777217.]))==Float64
    @test eltype(NE.exact_population_column([.1]))==Float64
    mktempdir() do dir
        fit,native,guides,out=[joinpath(dir,name) for name in ("fit","native","guides","export")]
        foreach(mkpath,(fit,native,guides));mkpath(joinpath(fit,"country-24"))
        ids=[H3.API.latLngToCell(H3.Lib.LatLng(0.,x),6) for x in (0.,.1)]
        points=hcat([[cos(H3.API.cellToLatLng(id).lng),sin(H3.API.cellToLatLng(id).lng),0.] for id in ids]...)
        meta=(;ids,population=[10.,10.],codes=[24,24],targets=[(0,0,24),(2,0,24)],xyz=points,labels=Dict(Int32(1)=>"City"))
        part=(;meta,source=Int32[1,2],target=Int32[1,2],weights=[.5,.5],labels=Dict(1=>"City"))
        serialize(joinpath(fit,"country-24","part.jls"),part)
        serialize(joinpath(guides,"codes.jls"),[24]);serialize(joinpath(guides,"owners.jls"),Dict())
        serialize(joinpath(guides,"country-24.jls"),(;meta=merge(meta,(;ids=H3.API.cellToParent.(ids,5)))))
        Arrow.write(joinpath(native,"all-res6.arrow"),(;id=ids,population=meta.population,country_code=meta.codes))
        write(joinpath(fit,"fit-complete.txt"),"complete");CSV.write(joinpath(fit,"summary.csv"),[(;code=24,status="optimized")])
        report=NE.export_native(fit,native,guides,out)
        @test report["sources"]==2
        @test report["population_type"]=="Float32"
        @test eltype(Arrow.Table(joinpath(out,"cartogram_weights_hilo.arrow")).population)==Float32
        @test report["labelled_sources"]==1
        @test report["source_error"]<1e-7
        @test report["density_relative_error"]<=6e-8
        @test eltype(Arrow.Table(joinpath(out,"population_density_hilo.arrow")).value)==Float32
        @test TOML.parsefile(joinpath(out,"audit.toml"))["factor"]==1
        @test_throws ErrorException NE.export_native(fit,native,guides,out)
        input=Arrow.Table(joinpath(native,"all-res6.arrow"))
        @test_throws ErrorException NE.metadata([merge(part,(;meta=merge(meta,(;population=[11.,10.]))))],input)
        @test_throws ErrorException NE.metadata([part,part],input)
        @test read(joinpath(out,"cartogram_weights_hilo.arrow"),6)==collect(codeunits("ARROW1"))
        write(joinpath(fit,"input.toml"),"target_retained = 0.99\n")
        @test_throws ErrorException NE.export_native(fit,native,guides,joinpath(dir,"reduced"))
    end
end
