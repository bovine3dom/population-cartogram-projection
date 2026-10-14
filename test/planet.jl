using Test
include(joinpath(@__DIR__,"..","examples","continuity","planet.jl"))

@testset "Mixed target cells are explicit cuts" begin
    a=(code=1,target=DataFrame(x=[0,2,4],y=[0,0,0]))
    b=(code=2,target=DataFrame(x=[0,0],y=[0,2]))
    edges=CE.graph([a,b];borders=Set([(1,2)]))
    @test edges==[(1,2,1,3)]
    @test CE.graph([b,a];borders=Set([(1,2)]))==[(2,2,2,3)]
    @test CE.graph([merge(a,(;cut_targets=Set([(0,0)])))])==[(1,2,1,3)]
end

@testset "Planet assembly retains coverage and city names" begin
    a=H3.API.latLngToCell(H3.API.LatLng(deg2rad(51.),deg2rad(13.)),5)
    b=H3.API.latLngToCell(H3.API.LatLng(deg2rad(52.),deg2rad(19.)),5)
    original=DataFrame(x=[0,2,2],y=[0,0,0],id=[a,a,b],code=[276,276,616],
        population=[100.,100.,200.],weight=[.4,.5,1.1],weight_mean=[1.,.2,.8],
        label=Union{Missing,String}["City A",missing,"City B"])
    replacement=DataFrame(x=[0,2],y=[0,0],id=[a,a],code=[276,276],weight=[.7,.299999],weight_mean=[1.,1.])
    d,sources=assemble(original,replacement)
    @test nrow(sources)==2
    @test Set(zip(d.x,d.y,d.code))==Set(zip(original.x,original.y,original.code))
    @test all(isapprox.(combine(groupby(d,[:index_lower,:index_upper]),:weight=>sum=>:total).total,1.))
    @test all(isapprox.(combine(groupby(d,[:x,:y]),:weight_mean=>sum=>:total).total,1.))
    @test Set(skipmissing(d.label))==Set(["City A","City B"])
    @test all(ismissing,d.prominence)
    @test Set((UInt64.(d.index_upper).<<32).|UInt64.(d.index_lower))==Set([a,b])
    shared=d[d.x.==2,:]
    @test shared.weight_mean[shared.code.==616][1] ≈ 200/sum(shared.weight.*shared.population)
    @test_throws ErrorException assemble(original,replacement[1:1,:])
end

@testset "Sparse publication target masses" begin
    c=(;code=1,source=DataFrame(value=[100.]),target=DataFrame(x=[0,2],y=[0,0]),b=[.5,.5])
    d=DataFrame(code=[1,1],x=[0,2],y=[0,0],weight=[.5,.5],population=[100.,100.])
    @test only(export_mass_checks([c],d).target_l1)==0
    d.weight=[.50006,.49994]
    @test_throws ErrorException export_mass_checks([c],d)
end

# Optional complete GPU workflow, including publication into a temporary directory.
if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
    @testset "Planet oneAPI workflow" begin
        mktempdir() do root
            rows=NamedTuple[]
            for (code,offset,longitude) in ((276,0,13.),(616,4,19.)), i in 1:2
                id=H3.API.latLngToCell(H3.API.LatLng(deg2rad(50.0+i),deg2rad(longitude+i)),5)
                for x in (offset,offset+2),y in (0,2)
                    push!(rows,(;x,y,code,weight=.25,weight_mean=.5,population=100.,
                        label=x==offset && y==0 ? "City $code-$i" : missing,
                        index_lower=UInt32(id & 0xffffffff),index_upper=UInt32(id>>32)))
                end
            end
            input=joinpath(root,"input.arrow");Arrow.write(input,DataFrame(rows))
            for compact in (false,true)
                out=joinpath(root,"study-$compact");dest=joinpath(root,"published-$compact")
                prepare(input,out)
                withenv("CONTINUITY_OUTER_STEPS"=>"1") do
                    fit(out;compact)
                end
                eta_file=joinpath(out,"fit","country-etas.csv")
                compact && CSV.write(eta_file,DataFrame(code=[276,616],eta=[.002,.002]))
                publish(out,dest)
                compact && @test read(joinpath(dest,"country-etas.csv"))==read(eta_file)
                @test isfile(joinpath(dest,"population_density_hilo.arrow"))
                @test isfile(joinpath(dest,"cartogram_weights_planet_h3_5_factor1_continuity_hilo.arrow"))
                @test isfile(joinpath(out,"published.txt"))
                @test isfile(joinpath(dest,"export-mass.csv"))
                @test !ispath(dest*".pending")
                @test_throws ErrorException publish(out,dest)
                compact && @test isfile(joinpath(out,"coarse-poses","poses.csv"))
            end
        end
    end
end
