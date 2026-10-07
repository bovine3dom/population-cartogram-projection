using Test
include(joinpath(@__DIR__, "..", "examples", "uk_h3.jl"))
include(joinpath(@__DIR__, "..", "scripts", "extract_kontur_country.jl"))
using .UKH3Example: Arrow, DataFrame, H3
include(joinpath(@__DIR__, "..", "examples", "uk-h3", "export_h3_mon.jl"))

@testset "UK H3 example" begin
    mktempdir() do dir
        ids = UInt64[0x08800014c5bfffff, 0x08800189425fffff]
        path = joinpath(dir, "source.arrow")
        source = DataFrame(id=ids, population=[10.0, 20.0], country_code=[826, 826])
        Arrow.write(path, source)
        @test UKH3Example.load_sources(path).value == source.population
        source.id[2] = H3.API.cellToParent(ids[2], 6)
        Arrow.write(path, source)
        @test_throws ErrorException UKH3Example.load_sources(path)
        source.id = H3.API.cellToParent.(ids, 6)
        Arrow.write(path, source)
        @test size(UKH3Example.load_sources(path), 1) == 2
        source.country_code[1] = 250
        Arrow.write(path, source)
        @test_throws ErrorException UKH3Example.load_sources(path)
    end
    base = UKH3Example.load_cartogram(826)
    subdivided = UKH3Example.load_cartogram(826; factor=3)
    @test size(subdivided, 1) == 9size(base, 1)
    @test allunique(zip(subdivided.x, subdivided.y))
end

@testset "H3-MON export" begin
    london = H3.API.latLngToCell(H3.API.LatLng(deg2rad(51.5074), deg2rad(-0.1278)), 7)
    sources = DataFrame(id=[london], population=[100.0], country_code=[826])
    mapping = DataFrame(id=[london, london], x=[0, 1], y=[0, 0],
                        weight=[0.8, 0.2], weight_mean=[1.0, 1.0])
    cities = DataFrame(name=["London", "Other name", "Excluded", "Unmatched"],
                       country_code=["GB", "GB", "FR", "GB"],
                       latitude=[51.5074, 51.5074, 51.5074, 0.0],
                       longitude=[-0.1278, -0.1278, -0.1278, 0.0],
                       population=[9_000_000, 100_000, 200_000, 100_000])
    result = UKH3MonExport.build_output(mapping, sources, cities)
    @test result.output.label[1] == "London, Other name"
    @test ismissing(result.output.label[2])
    @test result.output.prominence[1] == 9_000_000
    @test result.unmatched.name == ["Unmatched"]
    @test eltype(result.output.index_lower) == UInt32
    @test eltype(result.output.index_upper) == UInt32
    @test ((UInt64.(result.output.index_upper) .<< 32) .| UInt64.(result.output.index_lower)) == mapping.id
    @test result.output.weight == mapping.weight
    @test result.output.weight_mean == mapping.weight_mean
    @test result.output.population == [100.0, 100.0]
end

@testset "Parent population sums" begin
    parent = H3.API.latLngToCell(H3.API.LatLng(deg2rad(51.5074), deg2rad(-0.1278)), 7)
    children = H3.API.cellToChildren(parent, 8)
    population = Float64.(1:length(children))
    result = KonturCountryExtract.aggregate_sources(children, population, 826, 7)
    @test result.id == [parent]
    @test result.population == [sum(population)]
    @test result.country_code == [826]
    native = KonturCountryExtract.aggregate_sources(children, population, 826, 8)
    @test native.id == sort(children)
    @test sum(native.population) == sum(population)
    @test_throws ErrorException KonturCountryExtract.aggregate_sources(children, population, 826, 9)
end

@testset "H3 polygon holes" begin
    outer = [[-1., 50.], [1., 50.], [1., 52.], [-1., 52.], [-1., 50.]]
    hole = [[-0.5, 50.5], [0.5, 50.5], [0.5, 51.5], [-0.5, 51.5], [-0.5, 50.5]]
    filled = Set(KonturCountryExtract.polygon_cells([outer], 6))
    interior = Set(KonturCountryExtract.polygon_cells([hole], 6))
    with_hole = Set(KonturCountryExtract.polygon_cells([outer, hole], 6))
    @test !isempty(interior)
    @test with_hole == setdiff(filled, interior)
end
