using DataFrames
import H3
include("../bin/publish.jl")

@testset "Publish checked mappings" begin
    mktempdir() do root
        mapping=joinpath(root,"mapping");mkpath(mapping)
        job=joinpath(mapping,"mapping-job.json")
        destination=joinpath(root,"data","custom-map")
        OWIDLayout.write_json_atomic(job,Dict("complete"=>false))
        @test_throws ErrorException publish_mapping(mapping,destination)
        h=UInt64(H3.API.latLngToCell(H3.Lib.LatLng(0.,0.),5))
        sources=DataFrame(id=[1],group_id=["a"],h3=[h],x=[0.],y=[0.],value=[10.])
        targets=DataFrame(x=[0],y=[0],group_id=["a"],country=["USA"])
        rows,_=fit_pool(sources,targets)
        export_mapping(rows,sources,targets,joinpath(mapping,"h3-mon"))
        OWIDLayout.write_json_atomic(job,Dict("complete"=>true))
        density=joinpath(mapping,"h3-mon/population_density_hilo.arrow")
        bytes=read(density);open(io->write(io,"changed"),density,"a")
        @test_throws ErrorException publish_mapping(mapping,destination)
        @test !ispath(destination)
        write(density,bytes)
        @test publish_mapping(mapping,destination)==destination
        @test JSON.parsefile(joinpath(destination,"population_density_hilo.json"))["cartogram"]=="custom-map/cartogram_weights_hilo.arrow"
        @test read(joinpath(destination,"population_density_hilo.arrow"))==bytes
        checks=JSON.parsefile(joinpath(destination,"checks.json"))
        @test all(OWIDLayout.file_digest(joinpath(destination,f))==hash for (f,hash) in checks["files"])
        @test_throws ErrorException publish_mapping(mapping,destination)
    end
end
