using Test, OWIDLayout
include("load.jl")
include("../../test/block_slide.jl")

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
    rooted,check=OWIDLayout.seed_region(split,Dict(),fragmented;rounds=2,monotone=true)
    @test check.complete && haskey(check.monotone_roots,"a")
    @test length(OWIDLayout.connected_parts(rooted["a"];diagonals=true))==1
end

