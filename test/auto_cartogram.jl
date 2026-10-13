using Test
include(joinpath(@__DIR__, "..", "examples", "auto-cartogram", "audit.jl"))
using .IslandAudit: Arrow, CSV, DataFrames, H3, JSON
const IA = IslandAudit

rectangle(w, s, e, n) = [[w,s], [e,s], [e,n], [w,n], [w,s]]
feature(rings; country="360") = Dict("properties"=>Dict("ISO_N3_EH"=>country),
    "geometry"=>Dict("type"=>"Polygon", "coordinates"=>rings))
boundaries(features...) = Dict("type"=>"FeatureCollection", "features"=>collect(features))

@testset "Geographic component identity and input checks" begin
    a = feature([rectangle(100., 0., 100.04, 0.04)])
    b = feature([rectangle(101., 0., 101.04, 0.04)])
    forward = IA.geographic_components(boundaries(a,b), 360)
    reverse = IA.geographic_components(boundaries(b,a), 360)
    @test forward == reverse
    @test length(unique(c.component_id for c in forward)) == 2
    @test_throws ErrorException IA.geographic_components(boundaries(a,a), 360)
    @test_throws ErrorException IA.geographic_components(boundaries(a), 826)
    @test_throws ErrorException IA.geographic_components(
        boundaries(feature([[[0.,0.], [1.,0.], [1.,1.], [0.,1.]]])), 360)
    @test_throws ErrorException IA.geographic_components(
        boundaries(feature([rectangle(-179., 0., 179., 1.)])), 360)
    @test_throws ErrorException IA.geographic_components(
        boundaries(feature([rectangle(100., 0., NaN, 1.)])), 360)
end

@testset "H3 component membership, holes and populations" begin
    outer = rectangle(100., 0., 100.1, 0.1)
    hole = rectangle(100.03, 0.03, 100.07, 0.07)
    components = IA.geographic_components(boundaries(feature([outer,hole])), 360)
    owners, counts = IA.geographic_owners(components)
    filled = Set(IA.KonturCountryExtract.polygon_cells([outer], 8))
    excluded = Set(IA.KonturCountryExtract.polygon_cells([hole], 8))
    @test Set(keys(owners)) == setdiff(filled, excluded)
    @test sum(counts) == length(owners)
    id = first(keys(owners)); outside = first(excluded)
    table = DataFrames.DataFrame(h3=[id,outside], population=[90.,10.])
    result = IA.select_sources(table, owners)
    @test result.id == [id]
    @test result.value == [90.]
    @test result.component_index == [1]
    @test_throws ErrorException IA.select_sources(
        DataFrames.DataFrame(h3=[id,id], population=[1.,2.]), owners)
    for bad in [0., -1., NaN, Inf]
        @test_throws ErrorException IA.select_sources(
            DataFrames.DataFrame(h3=[id], population=[bad]), owners)
    end
    overlap = IA.geographic_components(boundaries(feature([outer]),
        feature([rectangle(100.02, 0.02, 100.12, 0.12)])), 360)
    @test_throws ErrorException IA.geographic_owners(overlap)
    small = IA.geographic_components(boundaries(feature([rectangle(100., 0., 100.000001, 0.000001)])), 360)
    @test last(IA.geographic_owners(small)) == [0]
end

@testset "Target components use side adjacency and unique ownership" begin
    raw = DataFrames.DataFrame(x=[0,2,4,10], y=[0,0,2,10], country=[360,360,360,826])
    result = IA.target_components(raw, 360)
    @test length.(getproperty.(result, :cells)) == [2,1]
    @test result == IA.target_components(reverse(raw), 360)
    @test result[1].target_id == "360:tile:0:0"
    @test_throws ErrorException IA.target_components(vcat(raw,raw[1:1,:]), 360)
    other_owner = copy(raw[1:1,:]); other_owner.country .= 826
    @test_throws ErrorException IA.target_components(vcat(raw,other_owner), 360)
    bad_grid = copy(raw); bad_grid.x[1] = 1
    @test_throws ErrorException IA.target_components(bad_grid, 360)
end

@testset "Integer budgets and partial-match capacity lower bound" begin
    ideal, counts = IA.tile_budgets([90.,10.], ["a","b"], 10)
    @test ideal == [9.,1.]
    @test counts == [9,1]
    _, counts = IA.tile_budgets([1.,1.,0.], ["b","a","c"], 1)
    @test counts == [0,1,0]
    for n in 1:50
        p = [13., 20., 99., 0.]
        ideal, counts = IA.tile_budgets(p, ["a","b","c","d"], n)
        @test sum(counts) == n
        @test all(abs.(counts .- ideal) .< 1)
        @test counts[4] == 0
    end
    @test_throws ErrorException IA.tile_budgets([0.], ["a"], 1)
    @test_throws ErrorException IA.tile_budgets([-1.,2.], ["a","b"], 1)
    match = (; label="island-a", component_index=1, target_index=1, status="reviewed")
    table, bound = IA.capacity_audit([90.,10.], [5,5], [match])
    @test bound == 40.
    @test sum(table.excess_population) == 0
    @test table.excess_population == [-40.,40.]
    @test table.group == ["island-a", "unmatched-remainder"]
    @test isnothing(last(IA.capacity_audit([90.,10.], [5,5], NamedTuple[])))
    @test isnothing(last(IA.capacity_audit([90.,10.], [5,5], [merge(match,(status="provisional",))])))
    _, coarse = IA.capacity_audit([80.,15.,5.], [2,3,5], [match])
    full = [(;label="island-$i",component_index=i,target_index=i,status="reviewed") for i in 1:3]
    _, fine = IA.capacity_audit([80.,15.,5.], [2,3,5], full)
    @test coarse <= fine
end

@testset "Saved Indonesia audit is internally consistent" begin
    dir = joinpath(@__DIR__, "..", "examples", "auto-cartogram", "results", "indonesia")
    components = CSV.read(joinpath(dir,"components.csv"), DataFrames.DataFrame)
    targets = CSV.read(joinpath(dir,"targets.csv"), DataFrames.DataFrame)
    saved = CSV.read(joinpath(dir,"capacity.csv"), DataFrames.DataFrame)
    manifest = JSON.parsefile(joinpath(dir,"manifest.json"))
    @test sum(components.population) == manifest["population_total"]
    @test sum(components.source_cells) == manifest["source_cells"]
    @test sum(targets.tiles) == manifest["target_tiles"]
    _, budgets = IA.tile_budgets(components.population, components.component_id, sum(targets.tiles))
    @test budgets == components.allocated_tiles
    @test sum(components.population[budgets .== 0]) == manifest["population_without_budget"]
    matches = [(; label=r.label, component_index=i,
        target_index=only(findall(==(r.label), coalesce.(targets.label, ""))), status="reviewed")
        for (i,r) in enumerate(eachrow(components)) if r.match_status == "reviewed"]
    calculated, bound = IA.capacity_audit(components.population, targets.tiles, matches)
    sort!(calculated,:group); sort!(saved,:group)
    @test calculated.group == saved.group
    @test calculated.population == saved.population
    @test calculated.tiles == saved.tiles
    @test calculated.excess_population ≈ saved.excess_population
    @test bound ≈ manifest["coarse_cross_component_lower_bound"]
    @test length(matches) == manifest["reviewed_matches"] == 4
end

@testset "Headless audit with synthetic files" begin
    mktempdir() do dir
        boundary = joinpath(dir,"boundary.geojson")
        data = boundaries(feature([rectangle(100.,0.,100.04,0.04)]),
                          feature([rectangle(101.,0.,101.04,0.04)]))
        open(io -> JSON.print(io,data), boundary,"w")
        components = IA.geographic_components(data,360)
        owners, _ = IA.geographic_owners(components)
        id_a = H3.API.latLngToCell(H3.API.LatLng(deg2rad(0.02),deg2rad(100.02)),8)
        id_b = H3.API.latLngToCell(H3.API.LatLng(deg2rad(0.02),deg2rad(101.02)),8)
        population = joinpath(dir,"population.arrow")
        Arrow.write(population, DataFrames.DataFrame(h3=[id_a,id_b],population=[90.,10.]))
        cartogram = joinpath(dir,"cartogram.csv")
        write(cartogram,"0,0,360\n10,0,360\n")
        matches_path = joinpath(dir,"matches.csv")
        matches = DataFrames.DataFrame(label=["A"],longitude=[100.02],latitude=[0.02],
            target_x=[0],target_y=[0],status=["reviewed"],evidence=["Synthetic fixture"])
        CSV.write(matches_path,matches)
        targets = IA.target_components(CSV.read(cartogram,DataFrames.DataFrame;header=[:x,:y,:country]),360)
        @test length(IA.resolve_matches(matches,owners,targets)) == 1
        @test_throws ErrorException IA.resolve_matches(vcat(matches,matches),owners,targets)
        wrong = copy(matches); wrong.target_x .= 8
        @test_throws ErrorException IA.resolve_matches(wrong,owners,targets)
        wrong = copy(matches); wrong.longitude .= 110
        @test_throws ErrorException IA.resolve_matches(wrong,owners,targets)
        out = joinpath(dir,"result")
        manifest = IA.run(population,boundary,cartogram,out;matches_path)
        @test manifest["population_total"] == 100.
        @test manifest["coarse_cross_component_lower_bound"] == 40.
        @test manifest["positive_components_without_budget"] == 1
        @test manifest["population_without_budget"] == 10.
        sources = DataFrames.DataFrame(Arrow.Table(joinpath(out,"source-components.arrow")))
        @test sort(sources.value) == [10.,90.]
        @test length(unique(sources.component_id)) == 2
        @test all(sources.country_code .== 360)
        @test Set(sources.id) == Set([id_a,id_b])
        @test isfile(joinpath(out,"overview.svg"))
        @test JSON.parsefile(joinpath(out,"manifest.json"))["target_tiles"] == 2
        @test_throws ErrorException IA.run(population,boundary,cartogram,out;matches_path)
        wrong = copy(matches); wrong.longitude .= 110
        CSV.write(matches_path,wrong)
        bad_out = joinpath(dir,"failed")
        @test_throws ErrorException IA.run(population,boundary,cartogram,bad_out;matches_path)
        @test !ispath(bad_out)
    end
end
