using Test
include(joinpath(@__DIR__, "..", "examples", "auto-cartogram", "prepare_layout.jl"))
const LI = LayoutInputs
include(joinpath(@__DIR__, "..", "examples", "auto-cartogram", "prepare_dissolved.jl"))
using .LayoutInputs: DataFrame, CSV, JSON

part(id, country, lon) = (; component_id=id, country_id=country,
    west=lon-0.1,east=lon+0.1,south=-0.1,north=0.1)

@testset "Equal Earth and constrained budgets" begin
    @test LI.project(0.,0.) == (0.,0.)
    @test LI.project(30.,40.)[1] ≈ -LI.project(-30.,40.)[1]
    @test LI.project(30.,40.)[2] ≈ -LI.project(30.,-40.)[2]
    @test all(isfinite, LI.project(180.,90.))
    @test sum(LI.budgets([999.,1.,1.],["a","b","c"],3;minimum=1)) == 3
    @test LI.budgets([999.,1.,1.],["a","b","c"],3;minimum=1) == [1,1,1]
    @test_throws ErrorException LI.budgets([999.,1.,1.],["a","b","c"],2;minimum=1)
end

@testset "Small-island groups conserve population within countries" begin
    parts = [part("a","A",0.),part("b","A",20.),part("c","A",21.),part("d","B",21.1)]
    counts, anchors, mass = LI.groups(parts,[90.,10.,0.01,1.],11)
    @test sum(counts) == 11
    @test anchors[3] == 2 # closer foreign region must never receive this island
    @test anchors[4] == 4
    @test sum(mass) ≈ 101.01
    @test all(counts[a]>0 for a in anchors)
    @test all(parts[i].country_id == parts[a].country_id for (i,a) in enumerate(anchors))
    counts, anchors, mass = LI.groups(parts,[90.,10.,0.01,1.],11;policy="omit")
    @test anchors == collect(1:4)
    @test sum(mass[counts.>0]) < 101.01
    @test_throws ErrorException LI.groups(parts,[90.,10.,0.01,1.],1)
    dateline = [part("a","A",175.),part("b","A",0.),part("c","A",-175.)]
    _, anchors, _ = LI.groups(dateline,[90.,90.,0.1],10)
    @test anchors[3] == 1
end

@testset "Coastline simplification keeps shared border vertices" begin
    ring = [[0.,0.],[1.,0.],[1.,0.5],[1.,1.],[0.,1.],[0.,0.]]
    protected = Dict((1.,0.)=>2,(1.,0.5)=>2,(1.,1.)=>2)
    points = LI.outline(ring,protected;tolerance=1.)
    @test all(LI.project(p...) in points for p in keys(protected))
    @test length(points)>=3
    @test LI.simplify_chain([(0.,0.),(0.5,0.),(1.,0.)],0.01) == [(0.,0.),(1.,0.)]
    a = (;rings=[ring]); b = (;rings=[[[1.,0.],[2.,0.],[2.,1.],[1.,1.],[1.,0.5],[1.,0.]]])
    @test LI.geographic_contacts([a,b]) == [(1,2)]
    # Contacts through a hole remain in the audit even though WKT cannot encode it.
    outer = [[-1.,-1.],[3.,-1.],[3.,3.],[-1.,3.],[-1.,-1.]]
    @test LI.geographic_contacts([(;rings=[outer,ring]),a]) == [(1,2)]
end

@testset "Input writer and reproducible group accounting" begin
    mktempdir() do dir
        boundary = joinpath(dir,"input.geojson")
        props = Dict{String,Any}("GU_A3"=>"XXX","ADM0_A3"=>"XXX","NAME"=>"Test","ISO_N3_EH"=>"999")
        rings = [[[0.,0.],[1.,0.],[1.,1.],[0.,1.],[0.,0.]]]
        geo = Dict("type"=>"FeatureCollection","features"=>[Dict("properties"=>props,
            "geometry"=>Dict("type"=>"Polygon","coordinates"=>rings))])
        open(io->JSON.print(io,geo),boundary,"w")
        component = only(LI.WorldComponents.polygons(geo))
        summary = joinpath(dir,"components.csv")
        CSV.write(summary,DataFrame(component_id=[component.component_id],population=[100.]))
        out = joinpath(dir,"out")
        LI.run(summary,boundary,out,10)
        manifest = JSON.parsefile(joinpath(out,"manifest.json"))
        @test manifest["represented_population"] == 100.
        @test manifest["tile_budget"] == 10
        @test startswith(read(joinpath(out,"input.wkt"),String),"STAGE 1\nOUTLINES 1")
        @test read(joinpath(out,"weights.tsv"),String) == "$(component.component_id)\t10\n"
        @test_throws ErrorException LI.run(summary,boundary,out,10)
        dissolved = joinpath(dir,"dissolved"); mkpath(dissolved)
        merge!(props,Dict("original_components"=>["old:a","old:b"],"population"=>100.,"source_cells"=>3))
        open(io->JSON.print(io,geo),joinpath(dissolved,"boundaries.geojson"),"w")
        open(io->JSON.print(io,Dict("population"=>100.)),joinpath(dissolved,"manifest.json"),"w")
        prepare_dissolved(dissolved)
        rows=CSV.read(joinpath(dissolved,"components.csv"),DataFrame)
        crosswalk=CSV.read(joinpath(dissolved,"original-to-dissolved.csv"),DataFrame)
        @test only(rows.component_id) == component.component_id
        @test only(rows.population) == 100.
        @test only(rows.source_cells) == 3
        @test crosswalk.original_component_id == ["old:a","old:b"]
        @test all(==(component.component_id),crosswalk.component_id)
        @test isfile(joinpath(dissolved,"complete.txt"))
        @test_throws ErrorException prepare_dissolved(dissolved)
    end
end
