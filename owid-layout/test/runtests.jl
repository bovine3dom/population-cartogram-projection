using Test, OWIDLayout, CSV
include("review.jl")
include("groups.jl")
include("group_population_resize.jl")

piece(id, mass, x, y) = Piece(id,mass,(x,y),(x-0.5,y-0.5,x+0.5,y+0.5))

@testset "Assignment" begin
    @test OWIDLayout.assignment([4.0 1 3; 2 0 5; 3 2 2]) == [2,1,3]
    @test OWIDLayout.assignment(zeros(3,4)) == [1,2,3]
    @test OWIDLayout.assignment(zeros(0,3)) == Int[]
    @test_throws ArgumentError OWIDLayout.assignment(zeros(4,3))
    @test_throws ArgumentError OWIDLayout.assignment(fill(NaN,1,1))
    for seed in 1:20
        cost = [Float64(mod(seed*i*j + 3i + j*j,17)-8) for i in 1:3, j in 1:4]
        chosen = OWIDLayout.assignment(cost)
        optimum = minimum(cost[1,i]+cost[2,j]+cost[3,k] for i in 1:4, j in 1:4, k in 1:4 if length(Set((i,j,k)))==3)
        @test sum(cost[i,chosen[i]] for i in 1:3) == optimum
    end
end

@testset "Identity invariants" begin
    s = [piece("east",10,10,0),piece("west",10,0,0)]
    t = [piece("a",10,0,0),piece("b",10,10,0)]
    result = match_identities(s,t)
    @test getproperty.(result,:source_id) == ["west","east"]
    @test result == match_identities(reverse(s),reverse(t))
    @test isempty(match_identities(s,Piece[]))
    @test_throws ArgumentError match_identities(Piece[],t)
    @test_throws ArgumentError match_identities([s;s],t)
    @test_throws ArgumentError match_identities(s,[t;t])
    @test_throws ArgumentError match_identities(s,t;relationship_weight=-1)
    @test count(r->isempty(r.source_id),match_identities(s,[t;piece("c",1,20,0)])) == 1
    @test only(match_identities([s[1]],[t[1]])).relationship_cost == 0
    @test_throws ArgumentError piece("bad",NaN,0,0)
    @test_throws ArgumentError piece("bad",0,0,0)
    @test_throws ArgumentError piece("bad",1,Inf,0)
    @test_throws ArgumentError Piece("bad",1,(0,0),(2,0,1,1))
end

@testset "Input geometry" begin
    parts = OWIDLayout.connected_parts([(0,0),(1,0),(4,4),(5,5)])
    @test length.(parts) == [2,1,1] # Diagonal contact is not a land connection.
    @test first(parts[2]) == (4,4)
    ring = [[0,0],[4,0],[4,4],[0,4],[0,0]]
    hole = [[1,1],[2,1],[2,2],[1,2],[1,1]]
    centre,bounds = OWIDLayout.geometry_descriptor(Dict("type"=>"Polygon","coordinates"=>[ring,hole]),0,0)
    @test centre[1] ≈ (32-1.5)/15
    @test centre[2] ≈ centre[1]
    @test bounds == (0,0,4,4)
    reversed,_ = OWIDLayout.geometry_descriptor(Dict("type"=>"Polygon","coordinates"=>[reverse(ring),reverse(hole)]),0,0)
    @test reversed == centre
    dateline = [[179,0],[-179,0],[-179,2],[179,2],[179,0]]
    centre,bounds = OWIDLayout.geometry_descriptor(Dict("type"=>"Polygon","coordinates"=>[dateline]),180,0)
    @test centre == (0,1)
    @test bounds == (-1,0,1,2)
end

@testset "Reviewed identities without overrides" begin
    root = normpath(joinpath(@__DIR__,"..",".."))
    codes = OWIDLayout.code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
    targets = read_targets(joinpath(root,"data","cartogram.csv"),codes)
    @test sum(p.mass for ps in values(targets) for p in ps) == 54967
    @test sum(length,values(targets)) == 286
    sources = Dict{String,Vector{Piece}}()
    for r in CSV.File(joinpath(@__DIR__,"fixtures","source-descriptors.csv"))
        p = Piece(r.id,r.mass,(r.x,r.y),(r.west,r.south,r.east,r.north))
        push!(get!(sources,String(r.scope),Piece[]),p)
    end
    lookup = Dict{String,String}()
    for scope in sort!(collect(keys(sources)))
        result = match_identities(sources[scope],targets[scope])
        @test isequal(result,match_identities(reverse(sources[scope]),reverse(targets[scope])))
        merge!(lookup,Dict(r.target_id=>r.source_id for r in result))
    end
    # The reference table is not accessible to match_identities.
    for r in CSV.File(joinpath(@__DIR__,"fixtures","expected-identities.csv"))
        @test lookup["$(r.country):$(r.target_part)"] == r.component_id
    end
end
