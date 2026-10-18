using DataFrames
import Arrow, H3, JSON

@testset "Grouped transport and Arrow export" begin
    h=UInt64(H3.API.latLngToCell(H3.Lib.LatLng(0.,0.),5))
    # Two islands share a coarse H3 parent, but not a population pool.
    s=DataFrame(id=[1,2,3],component_id=["a","b","c"],group_id=["island","island","main"],
        h3=[h,h,h],value=[10.,30.,60.],x=[0.,1.,3.],y=[0.,1.,1.])
    t=DataFrame(x=[0,1,8,9,10],y=[0,0,0,0,0],group_id=["island","island","main","main","main"],
        country=fill("CUSTOM",5))
    a,check=OWIDLayout.fit_pool(s[1:2,:],t[1:2,:])
    @test check["maximum_relative_target_error"]<=1e-6
    b,_=OWIDLayout.fit_pool(s[3:3,:],t[3:5,:])
    m=vcat(a,b)
    @test OWIDLayout.check_mapping(m,s,t)["population"]≈100.
    @test OWIDLayout.check_mapping(m,s,t)["cross_pool_population"]==0
    bad=copy(m);bad.x[1]=8
    @test_throws ErrorException OWIDLayout.check_mapping(bad,s,t)
    bad=copy(m);bad.weight[1]*=.9
    @test_throws ErrorException OWIDLayout.check_mapping(bad,s,t)
    bad=copy(m);bad.weight_mean[1]*=.9
    @test_throws ErrorException OWIDLayout.check_mapping(bad,s,t)
    @test_throws ErrorException OWIDLayout.fit_pool(s,t)
    # The sparse diagonal cannot balance unequal supplies; expansion fixes it.
    raw=DataFrame(id=[1,2],x=[0,1],y=[0,0],weight=[1.,1.])
    @test_throws ErrorException OWIDLayout.balance_mapping(raw,s[1:2,:],t[1:2,:];iterations=10,expansion_steps=0)
    fixed,check=OWIDLayout.balance_mapping(raw,s[1:2,:],t[1:2,:];iterations=1000,expansion_steps=1)
    @test check["added_pairs"]==2
    @test OWIDLayout.check_mapping(fixed,s[1:2,:],t[1:2,:])["population"]≈40
    mktempdir() do root
        out=joinpath(root,"custom")
        audit=OWIDLayout.export_mapping(m,s,t,out;codes=Dict("CUSTOM"=>901))
        arrow=Arrow.Table(joinpath(out,"cartogram_weights_hilo.arrow"))
        density=Arrow.Table(joinpath(out,"population_density_hilo.arrow"))
        @test eltype(arrow.index_lower)==UInt32
        @test eltype(arrow.x)==Int32
        @test Set(arrow.code)==Set([901])
        @test all(ismissing,arrow.label)
        @test sum(arrow.weight)≈1.
        @test all(==(100.),arrow.population)
        @test only(density.value)≈100/H3.API.cellAreaKm2(h)
        @test UInt64(only(density.index_upper))<<32|UInt64(only(density.index_lower))==h
        @test audit["tiles"]==5
        @test_throws ErrorException OWIDLayout.export_mapping(m,s,t,out)
    end
end

@testset "Three-input custom cartogram pipeline" begin
    mktempdir() do root
        population=joinpath(root,"population.arrow");boundary=joinpath(root,"boundary.geojson")
        cartogram=joinpath(root,"cartogram.csv");codes=joinpath(root,"codes.csv")
        function f(unit,country,x)
            ring=[[x,0.],[x+1,0.],[x+1,1.],[x,1.],[x,0.]]
            Dict("type"=>"Feature","properties"=>Dict("GU_A3"=>unit,"ADM0_A3"=>country,"NAME"=>unit,"ISO_N3_EH"=>"901"),
                "geometry"=>Dict("type"=>"Polygon","coordinates"=>[ring]))
        end
        geo=Dict("features"=>[f("CUSTOM","CUSTOM",0.),f("CUSTOM","CUSTOM",3.),f("OTHER","OTHER",10.)])
        open(io->JSON.print(io,geo),boundary,"w")
        ids=UInt64[H3.API.latLngToCell(H3.Lib.LatLng(deg2rad(y),deg2rad(x)),8) for (x,y) in ((.2,.2),(.8,.8),(3.5,.5),(10.5,.5),(20.,20.))]
        Arrow.write(population,(h3=ids,population=[10.,20.,10.,7.,3.]))
        write(codes,"alpha3,numeric\nCUSTOM,901\nOTHER,902\n")
        write(cartogram,"10,20,901\n12,20,901\n10,22,901\n12,22,901\n30,20,901\n")
        build=joinpath(root,"build")
        report=OWIDLayout.build_layout(population,boundary,cartogram,build;country_codes=codes,scope_crosswalk=nothing)
        @test report["complete"]
        @test report["layout"]["land_tiles"]==5
        # A regional layout need not contain any of the default scope pools.
        second=joinpath(root,"second")
        @test OWIDLayout.build_layout(population,boundary,cartogram,second;country_codes=codes)["complete"]
        @test read(joinpath(build,"layout/cells.csv"))==read(joinpath(second,"layout/cells.csv"))
        inputs=OWIDLayout.mapping_inputs(build;resolution=8)
        @test inputs.audit["represented_population"]==40
        @test inputs.audit["excluded_population"]["unrepresented"]==7
        @test inputs.audit["excluded_population"]["unmatched"]==3
        @test sum(inputs.sources.value)==40
        @test nrow(inputs.targets)==5
        coarse=OWIDLayout.mapping_inputs(build;resolution=0)
        @test Set(coarse.sources.component_id)==Set(inputs.sources.component_id)
        @test sum(coarse.sources.value)==40
        # Weak artwork pieces can share a declared pool. Keep this explicit.
        budgets=CSV.read(joinpath(second,"layout/budgets.csv"),DataFrame)
        pool=first(budgets.group_id)
        budgets.population_group.=pool;budgets.pool_population.=40.
        CSV.write(joinpath(second,"layout/budgets.csv"),budgets)
        assignments=CSV.read(joinpath(second,"layout/source-assignments.csv"),DataFrame)
        assignments.group_id.=pool
        CSV.write(joinpath(second,"layout/source-assignments.csv"),assignments)
        pooled=OWIDLayout.mapping_inputs(second;resolution=0)
        @test only(unique(pooled.targets.group_id))==pool
        @test pooled.audit["artwork_groups"]==2 && pooled.audit["population_pools"]==1
        @test length(unique(pooled.sources.component_id))==2
        @test_throws ErrorException OWIDLayout.mapping_inputs(build;resolution=9)
        output=joinpath(root,"mapping")
        job=OWIDLayout.fit_export(build,output;resolution=8)
        @test job["complete"]
        @test job["export"]["population"]≈40
        @test Set(Arrow.Table(joinpath(output,"h3-mon/cartogram_weights_hilo.arrow")).code)==Set([901])
        @test_throws ErrorException OWIDLayout.fit_export(build,output;resolution=8)
        @test_throws ErrorException OWIDLayout.fit_export(build,output;resolution=8,resume=true)
        # Simulate interruption after the final export. Verify all checkpoints.
        job["complete"]=false
        OWIDLayout.write_json_atomic(joinpath(output,"mapping-job.json"),job)
        @test OWIDLayout.fit_export(build,output;resolution=8,resume=true)["complete"]
        job["complete"]=false;OWIDLayout.write_json_atomic(joinpath(output,"mapping-job.json"),job)
        @test_throws ErrorException OWIDLayout.fit_export(build,output;resolution=7,resume=true)
        shard=joinpath(output,"shards/1.arrow")
        open(io->write(io,"changed"),shard,"a")
        @test_throws ErrorException OWIDLayout.fit_export(build,output;resolution=8,resume=true)
        @test_throws ErrorException OWIDLayout.build_layout(population,boundary,cartogram,build)
    end
end
