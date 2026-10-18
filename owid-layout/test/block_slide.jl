@testset "Rigid block slides" begin
    O=OWIDLayout
    a=Set((x,y) for x in 0:1 for y in 0:1)
    mask=Set((x,y) for x in 0:5 for y in 0:2);b=setdiff(mask,a)
    r=O.slide_exchange(a,b,(2,0))
    @test r.moving==Set((x+2,y) for (x,y) in a)
    @test length(r.receiving)==length(b)
    @test union(r.moving,r.receiving)==mask
    @test r.seam_tiles==0 && r.counter_rigid_tiles==4 && r.counter_shift==(-2,0)
    @test isempty(intersect(r.moving,r.receiving))
    inverse=O.slide_exchange(r.moving,r.receiving,(-2,0))
    @test inverse.moving==a && inverse.receiving==b
    @test O.slide_exchange(Set(reverse(sort!(collect(a)))),b,(2,0)).motions==r.motions
    overlap=O.slide_exchange(a,b,(1,0))
    @test overlap.overlap_tiles==2
    @test overlap.seam_tiles==0 && overlap.counter_shift==(-2,0) # One coherent strip, not two seam edits.
    @test_throws ArgumentError O.slide_exchange(a,b,(0,0))
    @test_throws ArgumentError O.slide_exchange(a,b,(20,0))
    @test_throws ArgumentError O.slide_exchange(a,union(a,b),(1,0))
    @test_throws ArgumentError O.slide_exchange(Set{Tuple{Int,Int}}(),b,(1,0))
    @test_throws ArgumentError O.slide_exchange(Set([(0,0),(0,1)]),Set([(1,0),(1,1),(2,0),(2,1)]),(1,0))
    elbow=Set([(0,0),(0,1),(0,2),(1,0)])
    surround=setdiff(Set((x,y) for x in -1:4 for y in -1:4),elbow)
    @test_throws ArgumentError O.slide_exchange(elbow,surround,(1,0))
    corner=O.slide_exchange(elbow,surround,(1,0);diagonals=true)
    @test corner.seam_tiles==1 && corner.counter_rigid_tiles==2
    @test length(corner.receiving)==length(surround)

    # Regression for the requested two-country example. The clean build only
    # translates this part of Africa; its shapes match original OWID here.
    owner=O.read_owid_cells(joinpath(@__DIR__,"../../data/cartogram.csv"))
    codes=O.code_table(joinpath(@__DIR__,"../config/country-codes.csv"))
    bfa=Set(p for (p,c) in owner if c==codes["BFA"])
    nga=Set(p for (p,c) in owner if c==codes["NGA"])
    actual=O.slide_exchange(bfa,nga,(4,-9))
    @test length(actual.moving)==159 && length(actual.receiving)==1562
    @test actual.counter_rigid_tiles==151 && actual.seam_tiles==4
    @test actual.counter_shift==(-4,9)
    @test length(O.connected_parts(actual.receiving))==1
    @test Set((r.from_x,r.from_y) for r in actual.motions)==Set((r.to_x,r.to_y) for r in actual.motions)
    @test length(unique((r.to_x,r.to_y) for r in actual.motions))==length(actual.motions)
    restored=O.slide_exchange(actual.moving,actual.receiving,(-4,9))
    @test restored.moving==bfa && restored.receiving==nga
    rigid=O.slide_exchange(bfa,nga,(7,-10))
    @test rigid.seam_tiles==0 && rigid.counter_rigid_tiles==159
end
