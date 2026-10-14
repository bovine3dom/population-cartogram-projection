using Test,H3,Random
include("../examples/continuity/native_membership.jl")
const NM=NativeMembership
square(x,y,r)=[[x-r,y-r],[x+r,y-r],[x+r,y+r],[x-r,y+r],[x-r,y-r]]
function naive(ring,x,y)
    inside=false
    for k in 1:length(ring)-1
        ax,ay=ring[k];bx,by=ring[k+1]
        ((ay>y)!=(by>y)) && x<ax+(y-ay)*(bx-ax)/(by-ay) && (inside=!inside)
    end
    inside
end
@testset "Native polygon membership" begin
    ring=[[-3.,-2.],[1.,-3.],[3.,1.],[0.,3.],[-3.,-2.]]
    bins=NM.ring_bins(ring);rng=MersenneTwister(8)
    points=[(8rand(rng)-4,8rand(rng)-4) for _ in 1:1000]
    @test all(NM.contains(bins,deg2rad(x),deg2rad(y))==naive(ring,x,y) for (x,y) in points)
    @test_throws ErrorException NM.ring_bins(ring[1:end-1])
    @test_throws ErrorException NM.ring_bins([[179.,-1.],[-179.,-1.],[-179.,1.],[179.,-1.]])
    feature(code,kind,coords)=Dict("properties"=>Dict("ISO_N3_EH"=>string(code)),
        "geometry"=>Dict("type"=>kind,"coordinates"=>coords))
    boundary=Dict("features"=>[
        feature(9,"Polygon",[square(0,0,3)]),
        feature(7,"MultiPolygon",[[square(0,0,3),square(0,0,1)],[square(11,11,1)]])])
    ids=[H3.API.latLngToCell(H3.Lib.LatLng(deg2rad(y),deg2rad(x)),8) for (x,y) in ((0,0),(2,0),(11,11),(20,20))]
    owner,overlap=NM.point_owners(ids,boundary,[7,9])
    @test owner==[9,7,7,0]
    @test overlap==1
    @test first(NM.point_owners(ids,boundary,[7]))==[0,7,7,0]
end
