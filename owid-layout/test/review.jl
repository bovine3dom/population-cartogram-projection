include(joinpath(@__DIR__,"..","src","review.jl"))

@testset "Identity review graphics" begin
    @test escape_markup("a<&\"b") == "a&lt;&amp;&quot;b"
    @test_throws ArgumentError padded_bounds(Tuple{Float64,Float64}[])
    @test padded_bounds([(0,0),(2,4)];padding=0) == (0,0,2,4)
    bounds = padded_bounds([(0,0)];minimum_span=2,padding=0)
    @test bounds == (-1,-1,1,1)
    transform,scale = panel_transform((0,0,2,4),10,20,100,100)
    @test scale == 25
    @test transform((0,4)) == (35,20)
    @test transform((2,0)) == (85,120)
    g = Dict("type"=>"Polygon","coordinates"=>[[[179,0],[-179,0],[-179,2],[179,2],[179,0]]])
    rings = geo_rings(g,180,0)
    @test first(first(first(rings))) == (-1,0)
    @test last(first(first(rings))) == (-1,0)
    io=IOBuffer()
    draw_tiles(io,Dict((0,0)=>"A:T1",(1,0)=>"A:T1"),"A:T1",(-1,-1,2,1),0,0,300,200,"test";labels=true)
    svg=String(take!(io))
    @test count("<rect ",svg)==3 # Two cells and a clip rectangle.
    @test count("<path ",svg)==6 # No shared internal edge.
    @test occursin(">T1</text>",svg)
    io=IOBuffer()
    draw_geography(io,Dict("a<b"=>rings),"a<b",(-2,-1,2,3),0,0,100,100,"blue","geo")
    @test occursin("a&lt;b",String(take!(io)))
end
