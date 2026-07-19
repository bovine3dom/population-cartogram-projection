using AMDGPU
using Arrow
using CSV
using CUDA
using DataFrames
using H3
import KernelAbstractions as KA
using PopulationCartogramProjection
using Test
using oneAPI

if Sys.isapple() && Sys.ARCH === :aarch64
    @eval using Metal
end

include(joinpath(@__DIR__, "..", "examples", "uk_h3.jl"))
include(joinpath(@__DIR__, "..", "examples", "france", "iris_population.jl"))

const QUICK_OPTIONS = (
    candidate_etas=Float32[0.5, 0.1, 0.05],
    base_eta_schedule=Float32[0.5, 0.1, 0.05],
    max_iters_per_eta=500,
    tol=1e-5,
    check_every=10,
)

function fixture()
    cartogram = DataFrame(x=[0, 1, 2], y=[0, 0, 0])
    sources = DataFrame(
        id=UInt64[0x8a2a10728907fff, 0x8a2a1072890ffff],
        x=[-1.0, 1.0],
        y=[51.0, 50.0],
        value=[40.0, 60.0],
    )
    return (; cartogram, sources)
end

function check_distribution(result, cartogram, sources; dense=false)
    @test propertynames(result) == [:x, :y, :id, :weight, :weight_mean]
    @test eltype(result.id) == eltype(sources.id)
    @test all(isfinite, result.weight)
    @test all(isfinite, result.weight_mean)
    @test all(value -> 0 < value <= 1, result.weight)
    @test all(value -> 0 < value <= 1, result.weight_mean)
    @test Set(zip(result.x, result.y)) <= Set(zip(cartogram.x, cartogram.y))
    dense && @test nrow(result) == nrow(cartogram) * nrow(sources)

    source_totals = combine(groupby(result, :id), :weight => sum => :weight)
    @test all(value -> isapprox(value, 1; atol=1e-8), source_totals.weight)
    target_totals = combine(groupby(result, [:x, :y]), :weight_mean => sum => :weight)
    @test all(value -> isapprox(value, 1; atol=1e-12), target_totals.weight)

    transported = leftjoin(result, select(sources, :id, :value); on=:id)
    transported.mass = transported.weight .* transported.value
    cell_mass = combine(groupby(transported, [:x, :y]), :mass => sum => :mass)
    expected = sum(sources.value) / nrow(cartogram)
    @test all(value -> isapprox(value, expected; rtol=2e-4), cell_mass.mass)
end

@testset "input contract" begin
    (; cartogram, sources) = fixture()
    backend = KA.CPU()
    @test_throws ArgumentError distribute(select(cartogram, :x), sources; backend)
    @test_throws ArgumentError distribute(cartogram, select(sources, Not(:id)); backend)
    @test_throws ArgumentError distribute(cartogram[1:0, :], sources; backend)
    @test_throws ArgumentError distribute(cartogram, sources[1:0, :]; backend)

    duplicate_cells = vcat(cartogram, cartogram[1:1, :])
    @test_throws ArgumentError distribute(duplicate_cells, sources; backend)
    collapsed_cells = DataFrame(x=BigInt[big(2)^54, big(2)^54 + 1], y=[0, 0])
    @test_throws ArgumentError distribute(collapsed_cells, sources; backend)
    signed_zero = DataFrame(x=[-0.0, 0.0], y=[0.0, 0.0])
    @test_throws ArgumentError distribute(signed_zero, sources; backend)
    duplicate_ids = vcat(sources, sources[1:1, :])
    @test_throws ArgumentError distribute(cartogram, duplicate_ids; backend)
    missing_id = copy(sources)
    allowmissing!(missing_id, :id)
    missing_id.id[1] = missing
    @test_throws ArgumentError distribute(cartogram, missing_id; backend)

    for value in (0.0, -1.0, Inf, NaN, true, big"1e400")
        invalid = copy(sources)
        invalid.value = Any[value, 1.0]
        @test_throws ArgumentError distribute(cartogram, invalid; backend)
    end
    invalid_coordinate = copy(sources)
    invalid_coordinate.x[1] = Inf
    @test_throws ArgumentError distribute(cartogram, invalid_coordinate; backend)
    @test_throws ArgumentError distribute(
        DataFrame(x=[0.0, nextfloat(0.0), 1.0], y=zeros(3)), sources; backend,
    )
    extreme_range = copy(sources)
    extreme_range.value = [nextfloat(0.0), 1.0]
    @test_throws ArgumentError distribute(cartogram, extreme_range; backend)

    @test_throws ArgumentError distribute(cartogram, sources; backend, cumulative_weight=0)
    @test_throws ArgumentError distribute(cartogram, sources; backend, minimum_weight=2)
    @test_throws ArgumentError distribute(cartogram, sources; backend, minimum_cells=4)
    @test_throws ArgumentError distribute(
        cartogram, sources; backend, minimum_cells=2, maximum_cells=1,
    )
    @test_throws ArgumentError distribute(cartogram, sources; backend, candidate_etas=Float32[])
    @test_throws ArgumentError distribute(cartogram, sources; backend, tol=1e-9)
    @test_throws TypeError distribute(cartogram, sources; backend, max_iters_per_eta=true)
    @test_throws TypeError distribute(cartogram, sources; backend, check_every=true)
end

@testset "balanced distribution" begin
    (; cartogram, sources) = fixture()
    result = distribute(
        cartogram,
        sources;
        backend=KA.CPU(),
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    check_distribution(result, cartogram, sources; dense=true)

    with_unused_columns = transform(sources, :id => ByRow(string) => :country)
    with_unused_columns.label = ["first", "second"]
    extra = distribute(
        transform(cartogram, :x => ByRow(string) => :country),
        with_unused_columns;
        backend=KA.CPU(),
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    @test extra == result

    permuted = distribute(
        cartogram,
        sources[[2, 1], :];
        backend=KA.CPU(),
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    @test sort(result, [:id, :x, :y]) ≈ sort(permuted, [:id, :x, :y])

    large_values = copy(sources)
    large_values.value .= [floatmax(Float64), floatmax(Float64) / 2]
    large_result = distribute(
        cartogram,
        large_values;
        backend=KA.CPU(),
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    @test all(isfinite, large_result.weight_mean)
    extreme_coordinates = distribute(
        DataFrame(x=[-floatmax(Float64), floatmax(Float64)], y=[0.0, 0.0]),
        sources;
        backend=KA.CPU(),
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    @test all(isfinite, extreme_coordinates.weight)

    symmetric_cartogram = DataFrame(x=[-1, 1], y=[0, 0])
    symmetric_source = DataFrame(id=["centre"], x=[0.0], y=[0.0], value=[1.0])
    selected = distribute(
        symmetric_cartogram,
        symmetric_source;
        backend=KA.CPU(),
        cumulative_weight=0.5,
        QUICK_OPTIONS...,
    )
    reversed = distribute(
        symmetric_cartogram[[2, 1], :],
        symmetric_source;
        backend=KA.CPU(),
        cumulative_weight=0.5,
        QUICK_OPTIONS...,
    )
    @test selected[:, [:x, :y]] == reversed[:, [:x, :y]]
end

@testset "automatic eta and sparsity" begin
    cartogram = DataFrame(x=[0, 0], y=[0, 2])
    sources = DataFrame(
        id=["north", "south"],
        x=[0.0, 0.0],
        y=[60.0, 50.0],
        value=[1.0, 1.0],
    )
    fit = PopulationCartogramProjection._fit_distribution(
        cartogram,
        sources,
        KA.CPU();
        target_rows_multiplier=0.5,
        cumulative_weight=0.995,
        QUICK_OPTIONS...,
    )
    @test fit.selected_eta == 0.1f0
    @test fit.rows == nrow(fit.mapping)
    @test fit.target_rows == 2
    @test fit.retained_value >= 0.995

    sparse = distribute(
        DataFrame(x=0:5, y=zeros(Int, 6)),
        DataFrame(
            id=["a", "b", "c"],
            x=[0.0, 0.5, 1.0],
            y=[1.0, 0.0, -1.0],
            value=[2.0, 3.0, 5.0],
        );
        backend=KA.CPU(),
        cumulative_weight=0.9,
        maximum_cells=3,
        QUICK_OPTIONS...,
    )
    @test maximum(combine(groupby(sparse, :id), nrow => :rows).rows) <= 3
    @test all(
        value -> isapprox(value, 1; atol=1e-12),
        combine(groupby(sparse, [:x, :y]), :weight_mean => sum => :weight).weight,
    )
end

function backend_result(backend)
    (; cartogram, sources) = fixture()
    return distribute(
        cartogram,
        sources;
        backend,
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
end

@testset "consumer-provided backends" begin
    @test !isdefined(PopulationCartogramProjection, :CUDA)
    @test !isdefined(PopulationCartogramProjection, :AMDGPU)
    @test !isdefined(PopulationCartogramProjection, :oneAPI)
    @test !isdefined(PopulationCartogramProjection, :Metal)
    expected = sort(backend_result(KA.CPU()), [:id, :x, :y])

    if CUDA.functional()
        actual = sort(backend_result(CUDA.CUDABackend()), [:id, :x, :y])
        @test actual.weight ≈ expected.weight atol=2e-4
        @test actual.weight_mean ≈ expected.weight_mean atol=2e-4
    end
    if AMDGPU.functional() && AMDGPU.has_rocm_gpu()
        actual = sort(backend_result(AMDGPU.ROCBackend()), [:id, :x, :y])
        @test actual.weight ≈ expected.weight atol=2e-4
        @test actual.weight_mean ≈ expected.weight_mean atol=2e-4
    end
    if oneAPI.functional()
        actual = sort(backend_result(oneAPI.oneAPIBackend()), [:id, :x, :y])
        @test actual.weight ≈ expected.weight atol=2e-4
        @test actual.weight_mean ≈ expected.weight_mean atol=2e-4
    end
    if Sys.isapple() && Sys.ARCH === :aarch64 && Metal.functional()
        actual = sort(backend_result(Metal.MetalBackend()), [:id, :x, :y])
        @test actual.weight ≈ expected.weight atol=2e-4
        @test actual.weight_mean ≈ expected.weight_mean atol=2e-4
    end
end

@testset "UK example adapter" begin
    api = H3.API
    parent = api.latLngToCell(api.LatLng(deg2rad(51.5), deg2rad(-0.1)), 5)
    @test !(parent isa api.H3ErrorCode)
    children = api.cellToChildren(parent, 6)
    @test !(children isa api.H3ErrorCode)
    ids = UInt64.(children[1:2])
    mktempdir() do directory
        path = joinpath(directory, "uk.arrow")
        Arrow.write(path, DataFrame(
            id=ids,
            population=[10.0, 20.0],
            country_code=[826, 826],
        ))
        sources = UKH3Example.load_sources(path)
        @test propertynames(sources) == [:id, :x, :y, :value]
        @test sources.id == ids
        @test sources.value == [10.0, 20.0]
        @test all(isfinite, sources.x)
        @test all(isfinite, sources.y)
    end
    @test nrow(UKH3Example.load_cartogram(826)) == 459
    subdivided = UKH3Example.load_cartogram(826; factor=2)
    @test nrow(subdivided) == 4 * 459
    @test allunique(zip(subdivided.x, subdivided.y))
end

@testset "France example adapter" begin
    loaded = FranceIrisExample.load_sources()
    @test propertynames(loaded.sources) == [:id, :x, :y, :value]
    @test nrow(loaded.sources) == 48_416
    @test loaded.report.input_rows == 49_276
    @test loaded.report.excluded_rows == 860
    @test loaded.report.missing_coordinate_rows == 708
    @test loaded.report.nonpositive_population_rows == 169
    @test all(length(collect(id)) == 9 for id in loaded.sources.id)
    @test "2A0040102" in loaded.sources.id
    @test eltype(loaded.sources.id) <: AbstractString
    @test nrow(loaded.attributes) == nrow(loaded.sources)
    @test nrow(FranceIrisExample.load_city_labels()) == 7
    @test nrow(FranceIrisExample.load_cartogram(250)) == 438

    cartogram = DataFrame(
        x=[0, 1],
        y=[0, 0],
        cell_id=["left", "right"],
        parent_cell_id=["left", "right"],
    )
    sources = DataFrame(
        id=["a", "b"], x=[0.0, 1.0], y=[0.0, 0.0], value=[40.0, 60.0],
    )
    mapping = distribute(
        select(cartogram, :x, :y),
        sources;
        backend=KA.CPU(),
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    projected = FranceIrisExample.projected_values(mapping, sources, cartogram)
    @test sum(projected.value) ≈ sum(sources.value)
    attributes = DataFrame(id=["a", "b"], population_density=[10.0, 20.0])
    density = FranceIrisExample.projected_density(mapping, sources, attributes, cartogram)
    @test all(value -> 10 <= value <= 20, density.population_density)
    dominant = FranceIrisExample.dominant_sources(mapping, sources, cartogram)
    @test all(.!ismissing.(dominant.id))
    labels = DataFrame(
        name=["A"], city_population=[1], latitude=[0.0], longitude=[0.0],
        id=["a"], country_code=[250],
    )
    placed = FranceIrisExample.place_city_labels(mapping, labels, cartogram)
    @test nrow(placed.placements) == 1
    @test count(!ismissing, placed.cells.label) == 1
end
