@testset "Same-country corner groups" begin
    cells=Dict((0,0)=>"A",(1,1)=>"A",(2,2)=>"B",(3,2)=>"B")
    result=OWIDLayout.target_groups(cells)
    @test length(result.pieces)==3
    @test length(result.groups)==2
    @test result.groups["A:G1"]==Set([(0,0),(1,1)])
    @test result.groups["B:G1"]==Set([(2,2),(3,2)])
    @test only(result.joins).scope=="A"
    @test only(result.joins).a=="A:T1"
    @test only(result.joins).b=="A:T2"
    @test result==OWIDLayout.target_groups(Dict(reverse(collect(cells))))
    @test sum(r.tiles for r in result.membership)==length(cells)
    @test length(unique(r.target_id for r in result.membership))==length(result.pieces)
    @test isempty(OWIDLayout.target_groups(Dict{Tuple{Int,Int},String}()).groups)
    @test length(OWIDLayout.connected_parts([(0,0),(1,1)]))==2
    @test length(OWIDLayout.connected_parts([(0,0),(1,1)];diagonals=true))==1
    @test length(OWIDLayout.connected_parts([(0,0),(2,2)];diagonals=true))==2
    codes=OWIDLayout.code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
    world=read_target_groups(joinpath(@__DIR__,"..","..","data","cartogram.csv"),codes)
    @test length(world.pieces)==286
    @test length(world.groups)==241
    @test sum(length,values(world.groups))==54967
    @test length(reduce(union,values(world.groups)))==54967
    @test count(g->startswith(g,"JPN:"),keys(world.groups))==1
    @test count(g->startswith(g,"PHL:"),keys(world.groups))==3
    @test count(g->startswith(g,"USA:"),keys(world.groups))==3
    membership=Dict(r.target_id=>r.group_id for r in world.membership)
    @test membership["USA:T2"]==membership["USA:T3"]
    @test membership["BRA:T1"]==membership["BRA:T2"]
    @test all(startswith(r.group_id,r.scope*":") for r in world.membership)
end
