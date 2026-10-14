using Test
include("../examples/continuity/mobile/pack_mapping.jl")

@testset "Pack a sparse fitted mapping" begin
    ids=[H3.API.latLngToCell(H3.API.LatLng(deg2rad(50.0+i),deg2rad(10.)),5) for i in 1:2]
    population=[100.,200.]
    function table(x,s,weight,label)
        mass=Dict(t=>sum(weight[i]*population[s[i]] for i in eachindex(x) if x[i]==t) for t in unique(x))
        (;x,y=zeros(Int,length(x)),code=10 .* s,weight,population=population[s],label,
            weight_mean=[weight[i]*population[s[i]]/mass[x[i]] for i in eachindex(x)],
            index_lower=UInt32.(ids[s].&0xffffffff),index_upper=UInt32.(ids[s].>>32))
    end
    mktempdir() do root
        input=joinpath(root,"input.arrow");mapping=joinpath(root,"mapping.arrow");density=joinpath(root,"density.arrow")
        Arrow.write(input,table([0,0,2,0,4],[1,1,1,2,2],[.4,.4,.2,.5,.5],
            Union{Missing,String}["A",missing,missing,missing,"B"]))
        Arrow.write(mapping,table([0,2,0,0,4],[1,1,2,2,2],[.8,.2,.25,.25,.5],
            Union{Missing,String}["A",missing,missing,missing,"B"]))
        values=population./H3.API.cellAreaKm2.(ids)
        Arrow.write(density,(index_lower=UInt32.(ids.&0xffffffff),index_upper=UInt32.(ids.>>32),value=values))
        out=joinpath(root,"packed")
        report=pack_mapping(input,mapping,density,out)
        @test report["ownership_rows"]==2
        @test report["sources"]==2 && report["labels"]==2
        @test report["target_tv_max"]<1e-6
        @test report["moment_reduction"]==false
        @test isfile(joinpath(out,"packing.toml")) && !ispath(out*".pending")
        @test_throws ErrorException pack_mapping(input,mapping,density,out)
        Arrow.write(density,(index_lower=UInt32.(ids.&0xffffffff),index_upper=UInt32.(ids.>>32),value=2values))
        bad=joinpath(root,"bad")
        @test_throws ErrorException pack_mapping(input,mapping,density,bad)
        @test !ispath(bad)
    end
end
