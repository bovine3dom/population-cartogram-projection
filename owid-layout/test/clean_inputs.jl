import Arrow, H3, JSON

@testset "Raw source preparation" begin
    function feature(id,country,rings)
        Dict("type"=>"Feature","properties"=>Dict("GU_A3"=>id,"ADM0_A3"=>country,"NAME"=>id,"ISO_N3_EH"=>"001"),
             "geometry"=>Dict("type"=>"Polygon","coordinates"=>rings))
    end
    square(x,y)=[[[x,y],[x+1,y],[x+1,y+1],[x,y+1],[x,y]]]
    boundary=Dict("features"=>[feature("a","X",square(0.,0.)),feature("b","X",square(1.,0.)),feature("c","X",square(2.,1.))])
    parts=OWIDLayout.natural_earth_parts(boundary);index=OWIDLayout.source_index(parts)
    @test OWIDLayout.source_owner(index,parts,.5,.5)==1
    @test OWIDLayout.source_owner(index,parts,1.,.5)==0 # Strict boundary exclusion.
    @test OWIDLayout.source_owner(index,parts,4.,4.)==0
    dissolved=OWIDLayout.dissolved_parts(parts,[10.,20.,30.],[1,1,1],index)
    @test length(dissolved.rows)==2 # Shared edge merges; corner contact does not.
    @test sum(r.population for r in dissolved.rows)==60
    @test sum(r.source_cells for r in dissolved.rows)==3
    @test length(dissolved.crosswalk)==3
    overlap=OWIDLayout.natural_earth_parts(Dict("features"=>[feature("a","X",square(0.,0.)),feature("d","Y",square(.25,.25))]))
    @test OWIDLayout.source_owner(OWIDLayout.source_index(overlap),overlap,.5,.5)==-1
    hole=[[.25,.25],[.75,.25],[.75,.75],[.25,.75],[.25,.25]]
    holed=OWIDLayout.natural_earth_parts(Dict("features"=>[feature("a","X",[first(square(0.,0.)),hole])]))
    @test OWIDLayout.source_owner(OWIDLayout.source_index(holed),holed,.5,.5)==0
    mktempdir() do root
        arrow=joinpath(root,"kontur.arrow");geo=joinpath(root,"natural-earth.geojson")
        ids=[H3.API.latLngToCell(H3.Lib.LatLng(deg2rad(y),deg2rad(x)),8) for (x,y) in ((.5,.5),(1.5,.5),(4.,4.))]
        Arrow.write(arrow,(h3=UInt64.(ids),population=[10.,20.,7.]))
        open(io->JSON.print(io,boundary),geo,"w")
        out=joinpath(root,"prepared")
        report=OWIDLayout.prepare_sources(arrow,geo,out)
        @test report.population==30
        @test report.unmatched_population==7
        @test report.ambiguous_population==0
        @test report.input_cells==3
        @test isfile(joinpath(out,"complete.txt"))
        @test length(collect(CSV.File(joinpath(out,"components.csv"))))==2
        @test_throws ErrorException OWIDLayout.prepare_sources(arrow,geo,out)
        duplicate=joinpath(root,"duplicate.arrow")
        Arrow.write(duplicate,(h3=UInt64[ids[1],ids[1]],population=[1.,2.]))
        @test_throws ErrorException OWIDLayout.prepare_sources(duplicate,geo,joinpath(root,"bad"))
        @test !ispath(joinpath(root,"bad"))
    end
end

@testset "Clean layout invariants" begin
    reference=Dict("AAA:G1"=>Set([(0,0),(0,1)]),"AAA:G2"=>Set([(8,0),(8,1)]))
    result,checks=OWIDLayout.fit_clean_layout(reference,Dict("AAA:G1"=>1,"AAA:G2"=>3))
    @test checks["complete"]
    @test checks["groups_connected"] && checks["scope_totals_exact"] && checks["coastal_groups_unchanged"]
    @test sum(length,values(result))==4
    again,_=OWIDLayout.fit_clean_layout(reference,Dict("AAA:G1"=>1,"AAA:G2"=>3))
    @test again==result
    invalid=Dict("AAA:G1"=>reference["AAA:G1"],"BBB:G1"=>reference["AAA:G2"])
    result,checks=OWIDLayout.fit_clean_layout(invalid,Dict("AAA:G1"=>1,"BBB:G1"=>3))
    @test result===nothing && !checks["scope_totals_exact"]
end

@testset "Regional exchanges" begin
    reference=Dict("a"=>Set([(0,0),(1,0)]),"b"=>Set([(0,1),(1,1)]))
    costs=[0. 10.;0. 10.;10. 0.;10. 0.]
    required=Set([("a","b")])
    result,report=OWIDLayout.exchange_region(reference,Dict(),required,costs;perimeter_weight=0.)
    @test result["a"]==Set([(0,0),(0,1)])
    @test result["b"]==Set([(1,0),(1,1)])
    @test report.topology_exact
    @test sum(r.objective_reduction for r in report.sweeps)==20
    again,_=OWIDLayout.exchange_region(reference,Dict(),required,costs;perimeter_weight=0.)
    @test again==result
    seeded,check=OWIDLayout.seed_region(reference,Dict(),costs)
    @test check.complete && seeded==result
    @test_throws ErrorException OWIDLayout.seed_region(reference,Dict(),zeros(3,2))
    mask=Set((x,y) for x in 0:3 for y in 0:1)
    split=Dict("a"=>Set([(0,0),(0,1)]),"b"=>setdiff(mask,Set([(0,0),(0,1)])))
    fragmented=hcat(fill(10.,8),zeros(8)) # Prefer two distant corners for a.
    fragmented[[1,8],1].=0.;fragmented[[1,8],2].=5.
    connected,check=OWIDLayout.seed_region(split,Dict(),fragmented;rounds=2)
    @test check.complete
    @test length(OWIDLayout.connected_parts(connected["a"];diagonals=true))==1
end

@testset "Shared outline partition" begin
    reference=Dict("a"=>Set([(0,0),(0,1)]),"b"=>Set([(1,0),(1,1)]))
    footprint=union(values(reference)...)
    result,report=OWIDLayout.partition_groups(reference,footprint,Dict("a"=>1,"b"=>3))
    @test report.complete
    @test length(result["a"])==1 && length(result["b"])==3
    @test OWIDLayout.edge_contacts(OWIDLayout.group_owners(result))==Set([("a","b")])
    again,_=OWIDLayout.partition_groups(reference,footprint,Dict("a"=>1,"b"=>3))
    @test again==result
    @test_throws ErrorException OWIDLayout.partition_groups(reference,footprint,Dict("a"=>1,"b"=>4))
    outside=Dict((2,0)=>"c",(2,1)=>"c")
    fitted,check=OWIDLayout.partition_groups(reference,footprint,Dict("a"=>1,"b"=>3);
        outside,required=Set([("a","b")]),free_outside_contacts=true,perimeter_weight=2.,cell_costs=zeros(4,2))
    @test check.complete && check.free_outside_contacts
    @test OWIDLayout.edge_contacts(OWIDLayout.group_owners(fitted))==Set([("a","b")])
    @test_throws ErrorException OWIDLayout.partition_groups(reference,footprint,Dict("a"=>1,"b"=>3);cell_costs=zeros(3,2))
    @test_throws ErrorException OWIDLayout.partition_groups(reference,footprint,Dict("a"=>1,"b"=>3);perimeter_weight=-1.)
    _,soft=OWIDLayout.partition_groups(reference,footprint,Dict("a"=>2,"b"=>2);
        required=Set{Tuple{String,String}}(),contact_penalty=100.,start_reference=true)
    @test soft.complete && !soft.topology_exact # A fixed connected mask cannot remove this contact.
    @test_throws ErrorException OWIDLayout.partition_groups(reference,footprint,Dict("a"=>2,"b"=>2);contact_penalty=-1.)
    remaining,seed=OWIDLayout.seed_scope(Set((x,y) for x in 1:4 for y in 1:4),5,(1.,1.))
    @test length(seed)==5 && length(remaining)==11
    @test length(OWIDLayout.connected_parts(seed;diagonals=true))==1
    @test length(OWIDLayout.connected_parts(remaining;diagonals=true))==1
end
