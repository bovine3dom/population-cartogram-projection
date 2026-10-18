@testset "Grouped population and resizing" begin
    @test OWIDLayout.allocate_tiles([9.,1.],10)==[9,1]
    @test OWIDLayout.allocate_tiles([99.,1.],3)==[2,1]
    @test OWIDLayout.allocate_tiles([1.,1.,1.],5)==[2,2,1]
    @test OWIDLayout.allocate_tiles([90.,5.,5.],10;floors=[1,2,2])==[6,2,2]
    @test_throws ArgumentError OWIDLayout.allocate_tiles([1.,1.],1)
    @test_throws ArgumentError OWIDLayout.allocate_tiles([0.,1.],2)
    @test_throws ArgumentError OWIDLayout.allocate_tiles([1.],1.2)
    @test_throws ArgumentError OWIDLayout.allocate_tiles([1.],Inf)
    square(x) = Dict("type"=>"Polygon","coordinates"=>[[[x-1,-1],[x+1,-1],[x+1,1],[x-1,1],[x-1,-1]]])
    features=[Dict("properties"=>Dict("component_id"=>id),"geometry"=>g) for (id,g) in
        (("a",square(-5)),("b",square(-3)),("c",Dict("type"=>"Polygon","coordinates"=>[[[-4,1],[-2,1],[-2,3],[-4,3],[-4,1]]])))]
    neighbours=OWIDLayout.source_neighbours(features,Dict("a"=>"X","b"=>"Y","c"=>"Z"))
    @test neighbours["a"]==Set(["Y"])
    @test neighbours["b"]==Set(["X","Z"])
    @test neighbours["c"]==Set(["Y"]) # Corner contact is not a source border.
    ring=[(-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.),(-1.,-1.)]
    @test OWIDLayout.point_geometry_distance((0.,0.),[[ring]],0)==0
    @test OWIDLayout.point_geometry_distance((3.,0.),[[ring]],0)==2
    @test OWIDLayout.point_geometry_distance((3.,0.),[[ring]],60)≈1
    hole=[(-.5,-.5),(.5,-.5),(.5,.5),(-.5,.5),(-.5,-.5)]
    @test OWIDLayout.point_geometry_distance((0.,0.),[[ring,hole]],0)==.5
    sources=[Piece("a",90,(-5.,0.),(-6.,-1.,-4.,1.)),Piece("b",10,(5.,0.),(4.,-1.,6.,1.))]
    targets=[Piece("X:G1",10,(0.,0.),(-6.,-1.,6.,1.))]
    # read_sources uses coordinates relative to the largest component's bounds centre.
    relative=[Piece(p.id,p.mass,(p.centre[1]+5,p.centre[2]),(p.bounds[1]+5,p.bounds[2],p.bounds[3]+5,p.bounds[4])) for p in sources]
    source_rows=Dict("a"=>(west="-6",east="-4",south="-1",north="1"),"b"=>(west="4",east="6",south="-1",north="1"))
    geometry=Dict("a"=>square(-5),"b"=>square(5))
    result=OWIDLayout.match_group_population(relative,targets,geometry,source_rows,10)
    @test result.budgets==Dict("X:G1"=>10)
    @test sum(r.population for r in result.assignments)==100
    @test all(r.group_id=="X:G1" for r in result.assignments)
    @test length(result.assignments)==2
    both=[Piece("X:G1",9,(-5.,0.),(-6.,-1.,-4.,1.)),Piece("X:G2",1,(5.,0.),(4.,-1.,6.,1.))]
    constrained=match_identities(sources,both;allowed=(t,s)->s.id=="a",allow_unmatched=true)
    @test count(r->isempty(r.source_id),constrained)==1
    @test_throws ArgumentError match_identities(sources,both;allowed=(t,s)->false)
    # Neither a false source border nor a reviewed identity is needed.
    matched=OWIDLayout.match_group_population(relative,both,geometry,source_rows,10)
    @test matched.budgets==Dict("X:G1"=>9,"X:G2"=>1)
    @test matched==OWIDLayout.match_group_population(reverse(relative),reverse(both),geometry,source_rows,10)
    ref=Set([(0,0),(1,1),(2,1),(3,1)])
    for n in (1,2,4,8,20)
        shape=OWIDLayout.scaled_group_outline(ref,n,(2.,1.))
        @test length(shape)==n
        @test length(OWIDLayout.connected_parts(shape;diagonals=true))==1
        @test isempty(OWIDLayout.enclosed_cells(shape))
        @test shape==OWIDLayout.scaled_group_outline(Set(reverse(sort!(collect(ref)))),n,(2.,1.))
    end
    lake=Set((x,y) for x in 0:2 for y in 0:2 if (x,y)!=(1,1))
    @test OWIDLayout.enclosed_cells(lake)==Set([(1,1)])
    @test !OWIDLayout.open_water_add(setdiff(lake,Set([(1,0)])),(1,0))
    current=Dict("X:G1"=>Set([(0,0),(1,0),(0,1),(1,1)]),"X:G2"=>Set([(12,0),(13,0)]))
    budgets=Dict("X:G1"=>3,"X:G2"=>3)
    fitted,checks=OWIDLayout.resize_groups(current,current,budgets)
    @test fitted!==nothing
    @test checks["complete"]
    @test length(fitted["X:G1"])==3 && length(fitted["X:G2"])==3
    @test sum(length,values(current))==6 # No mutation of the input.
    @test OWIDLayout.resize_groups(current,current,budgets)==(fitted,checks)
    @test_throws ArgumentError OWIDLayout.resize_groups(current,current,Dict("X:G1"=>4,"X:G2"=>3))
    attached=Dict("X:G1"=>Set([(0,0),(1,0),(0,1),(1,1)]),"Y:G1"=>Set([(2,0)]),"X:G2"=>Set([(12,0),(13,0)]))
    budgets=Dict("X:G1"=>3,"X:G2"=>3,"Y:G1"=>1)
    fitted,checks=OWIDLayout.resize_groups(attached,attached,budgets)
    @test fitted!==nothing
    @test checks["contacts_unchanged"] && checks["water_unchanged"]
    @test fitted["Y:G1"]==attached["Y:G1"]
    @test sum(length,values(fitted))==7
end
