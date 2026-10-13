using Test, DataFrames, Arrow, CSV, H3, JSON
include(joinpath(@__DIR__,"..","examples","auto-cartogram","group_transport.jl"))
using .IslandTransport

@testset "Declared island groups restrict transport" begin
    targets=DataFrame(x=[0,1,5],y=[0,0,0],group_id=["a","a","b"])
    sources=DataFrame(id=["a1","b1","b2"],x=[5.,0.,1.],y=[0.,1.,0.],
                      value=[60.,30.,10.],group_id=["a","b","b"])
    mapping,summary=IslandTransport.solve(targets,sources)
    @test summary.cross_group_population == 0
    @test summary.retained_population == 100
    @test summary.retained_share == 1
    @test nrow(mapping) == 4
    @test sum(mapping.weight[mapping.id .== "a1"]) == 1
    @test all(mapping.x[mapping.id .== "a1"] .< 5)
    @test all(mapping.x[mapping.id .!= "a1"] .== 5)
    bad=copy(targets); bad.group_id[3]="unknown"
    @test_throws ErrorException IslandTransport.solve(bad,sources)
    @test_throws ArgumentError IslandTransport.solve(vcat(targets,targets[1:1,:]),sources)
    invalid=copy(sources); invalid.x[1]=NaN
    @test_throws ArgumentError IslandTransport.solve(targets,invalid)
    pooled,report=IslandTransport.solve(targets,sources;pooled=true)
    @test report.cross_group_population > 0
    @test .995 <= report.retained_share <= 1.000001
end

@testset "North-up mosaic coordinates match the solver screen convention" begin
    targets=DataFrame(x=[0,0,0],y=[0,5,10],group_id=["south","middle","north"])
    sources=DataFrame(id=["s","m","n"],x=[0.,0.,0.],y=[0.,5.,10.],value=ones(3),group_id=copy(targets.group_id))
    mapping,summary=IslandTransport.solve(targets,sources;pooled=true)
    @test summary.cross_group_population < 1e-6
    north=filter(:id=>==("n"),mapping)
    @test north.y[argmax(north.weight)] == 10
end

@testset "Coarse source accounting and atomic export" begin
    mktempdir() do dir
        inputs=joinpath(dir,"input"); layout=joinpath(dir,"layout")
        mkpath(inputs); mkpath(layout)
        id=H3.API.cellToParent(UInt64(0x8a2a10728907fff),8)
        source=joinpath(dir,"sources.arrow")
        Arrow.write(source,(;id=[id],value=[10.],component_id=["old:abc"]))
        CSV.write(joinpath(inputs,"groups.csv"),DataFrame(component_id=["new:abc"],group_id=["new:abc"],tiles=[1],group_population=[10.]))
        CSV.write(joinpath(layout,"cells.csv"),DataFrame(component_id=["new:abc"],x=[0],y=[0]))
        write(joinpath(layout,"complete.txt"),"mode=test\n")
        output=joinpath(dir,"out")
        IslandTransport.run(source,inputs,layout,output,3)
        metadata=JSON.parsefile(joinpath(output,"manifest.json"))
        @test metadata["cross_group_population"] == 0
        @test metadata["source_population"] == 10
        @test metadata["retained_population"] == 10
        @test metadata["coarse_sources"] == 1
        @test isfile(joinpath(output,"mapping.csv"))
        @test_throws ErrorException IslandTransport.run(source,inputs,layout,output,3)
        groups=CSV.read(joinpath(inputs,"groups.csv"),DataFrame)
        groups.group_population[1]=11
        CSV.write(joinpath(inputs,"groups.csv"),groups)
        @test_throws ErrorException IslandTransport.run(source,inputs,layout,joinpath(dir,"bad"),3)
        @test !ispath(joinpath(dir,"bad"))
    end
end
