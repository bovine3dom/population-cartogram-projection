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
include(joinpath(@__DIR__, "..", "examples", "europe", "europe.jl"))

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
    @test_throws ArgumentError distribute(cartogram, sources; backend, cost_mode=:invalid)
    @test_throws ArgumentError distribute(
        cartogram, sources; backend, cost_mode=:matrix_free, cost_power=1,
    )
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

@testset "matrix-free tiled costs" begin
    (; cartogram, sources) = fixture()
    dense = sort(distribute(
        cartogram,
        sources;
        backend=KA.CPU(),
        cost_mode=:dense,
        cumulative_weight=1,
        QUICK_OPTIONS...,
    ), [:id, :x, :y])
    matrix_free = sort(distribute(
        cartogram,
        sources;
        backend=KA.CPU(),
        cost_mode=:matrix_free,
        cumulative_weight=1,
        QUICK_OPTIONS...,
    ), [:id, :x, :y])
    @test matrix_free[:, [:id, :x, :y]] == dense[:, [:id, :x, :y]]
    @test matrix_free.weight ≈ dense.weight atol=2e-5
    @test matrix_free.weight_mean ≈ dense.weight_mean atol=2e-5

    one_cell = distribute(
        DataFrame(x=[0], y=[0]),
        sources;
        backend=KA.CPU(),
        cost_mode=:matrix_free,
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
    check_distribution(one_cell, DataFrame(x=[0], y=[0]), sources; dense=true)

    tiled_cartogram = DataFrame(x=collect(0:36), y=mod.(0:36, 7))
    tiled_sources = DataFrame(
        id=collect(1:9),
        x=collect(range(-2, 2; length=9)),
        y=collect(range(55, 47; length=9)),
        value=Float64.(1:9),
    )
    dense_problem = PopulationCartogramProjection._prepare_problem(
        tiled_cartogram, tiled_sources; cost_power=2, cost_mode=:dense,
    )
    matrix_free_problem = PopulationCartogramProjection._prepare_problem(
        tiled_cartogram, tiled_sources; cost_power=2, cost_mode=:matrix_free,
    )
    @test maximum(
        abs(
            Float64(dense_problem.cost[source, target]) -
            Float64(PopulationCartogramProjection._cost(
                matrix_free_problem, source, target,
            )),
        )
        for source in 1:nrow(tiled_sources), target in 1:nrow(tiled_cartogram)
    ) <= 2e-6

    tiled_options = (
        candidate_etas=Float32[0.1],
        base_eta_schedule=Float32[0.1],
        max_iters_per_eta=500,
        tol=1e-5,
        check_every=10,
        cumulative_weight=1,
    )
    tiled_dense = sort(distribute(
        tiled_cartogram,
        tiled_sources;
        backend=KA.CPU(),
        cost_mode=:dense,
        tiled_options...,
    ), [:id, :x, :y])
    tiled_matrix_free = sort(distribute(
        tiled_cartogram,
        tiled_sources;
        backend=KA.CPU(),
        cost_mode=:matrix_free,
        tiled_options...,
    ), [:id, :x, :y])
    @test tiled_matrix_free[:, [:id, :x, :y]] == tiled_dense[:, [:id, :x, :y]]
    @test tiled_matrix_free.weight ≈ tiled_dense.weight atol=2e-5
    @test tiled_matrix_free.weight_mean ≈ tiled_dense.weight_mean atol=2e-5

    close_cartogram = DataFrame(x=Float64[0, 33_554_432, 33_554_433], y=zeros(3))
    close_sources = DataFrame(
        id=1:3, x=[0.0, 0.5, 1.0], y=zeros(3), value=ones(3),
    )
    close_options = (
        candidate_etas=Float32[1e-6],
        base_eta_schedule=Float32[0.1, 0.01, 0.001, 0.0001, 1e-5, 1e-6],
        max_iters_per_eta=10_000,
        tol=0.02,
        check_every=20,
        cumulative_weight=1,
    )
    close_dense = sort(distribute(
        close_cartogram,
        close_sources;
        backend=KA.CPU(),
        cost_mode=:dense,
        close_options...,
    ), [:id, :x])
    close_matrix_free = sort(distribute(
        close_cartogram,
        close_sources;
        backend=KA.CPU(),
        cost_mode=:matrix_free,
        close_options...,
    ), [:id, :x])
    @test close_matrix_free[:, [:id, :x]] == close_dense[:, [:id, :x]]
    @test close_matrix_free.weight ≈ close_dense.weight atol=1e-8

    small_terms = 100_000
    small_logit = Float32(log(1e-8))
    reduction_dual = fill(small_logit, small_terms + 1)
    reduction_dual[1] = 0
    accumulator_problem = PopulationCartogramProjection.DenseProblem(
        zeros(Float32, 1, small_terms + 1),
        Float32[1],
        fill(inv(Float32(small_terms + 1)), small_terms + 1),
    )
    logsum = PopulationCartogramProjection._matrix_free_cpu_value(
        accumulator_problem,
        Float32[0],
        reduction_dual,
        Float32[1],
        1.0f0,
        1,
        small_terms + 1,
        Val(true),
        Val(false),
    )
    @test logsum ≈ log1p(small_terms * exp(Float64(small_logit))) atol=1e-7
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
    matrix_free_fit = PopulationCartogramProjection._fit_distribution(
        cartogram,
        sources,
        KA.CPU();
        cost_mode=:matrix_free,
        target_rows_multiplier=0.5,
        cumulative_weight=0.995,
        QUICK_OPTIONS...,
    )
    @test matrix_free_fit.selected_eta == fit.selected_eta
    @test matrix_free_fit.rows == fit.rows
    @test matrix_free_fit.retained_value ≈ fit.retained_value atol=2e-5

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

function backend_result(backend; cost_mode=:dense)
    (; cartogram, sources) = fixture()
    return distribute(
        cartogram,
        sources;
        backend,
        cost_mode,
        cumulative_weight=1,
        QUICK_OPTIONS...,
    )
end

function check_backend(backend, expected)
    for cost_mode in (:dense, :matrix_free)
        actual = sort(backend_result(backend; cost_mode), [:id, :x, :y])
        @test actual.weight ≈ expected.weight atol=2e-4
        @test actual.weight_mean ≈ expected.weight_mean atol=2e-4
    end
end

@testset "consumer-provided backends" begin
    @test !isdefined(PopulationCartogramProjection, :CUDA)
    @test !isdefined(PopulationCartogramProjection, :AMDGPU)
    @test !isdefined(PopulationCartogramProjection, :oneAPI)
    @test !isdefined(PopulationCartogramProjection, :Metal)
    expected = sort(backend_result(KA.CPU()), [:id, :x, :y])

    if CUDA.functional()
        check_backend(CUDA.CUDABackend(), expected)
    end
    if AMDGPU.functional() && AMDGPU.has_rocm_gpu()
        check_backend(AMDGPU.ROCBackend(), expected)
    end
    if oneAPI.functional()
        check_backend(oneAPI.oneAPIBackend(), expected)
    end
    if Sys.isapple() && Sys.ARCH === :aarch64 && Metal.functional()
        check_backend(Metal.MetalBackend(), expected)
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

@testset "Europe example orchestration" begin
    countries = EuropeExample.load_countries()
    @test nrow(countries) == 42
    @test countries.name[1] == "Iceland"
    france = only(eachrow(filter(:name => ==("France"), countries)))
    @test france.cartogram_code == 250
    @test france.source_code == 249

    api = H3.API
    parent = api.latLngToCell(api.LatLng(deg2rad(48.85), deg2rad(2.35)), 5)
    children = api.cellToChildren(parent, 6)
    ids = UInt64.(children[1:2])
    for id in ids
        @test ((UInt64(EuropeExample.upper_uint32(id)) << 32) |
               UInt64(EuropeExample.lower_uint32(id))) == id
    end

    mapping = DataFrame(
        x=[0, 0],
        y=[0, 0],
        id=ids,
        weight=[1.0, 1.0],
        weight_mean=[1 / 3, 2 / 3],
        population=[10.0, 20.0],
        code=[249, 249],
        label=Union{Missing,String}["Paris", missing],
    )
    output = EuropeExample.hilo_output(mapping)
    @test propertynames(output) == [
        :x, :y, :weight, :population, :code, :label, :weight_mean,
        :index_lower, :index_upper,
    ]
    @test all(Missing <: eltype(output[!, column]) for column in propertynames(output))
    @test nonmissingtype(eltype(output.index_lower)) == UInt32
    @test nonmissingtype(eltype(output.index_upper)) == UInt32
    source_fixture = DataFrame(
        id=ids,
        x=zeros(2),
        y=zeros(2),
        value=[10.0, 20.0],
        country_code=fill(249, 2),
    )
    EuropeExample.validate_output(
        output, countries[6:6, :]; sources=source_fixture,
    )
    mislabeled = copy(output)
    mislabeled.weight_mean .= 0.5
    @test_throws ErrorException EuropeExample.validate_output(
        mislabeled, countries[6:6, :]; sources=source_fixture,
    )
    malformed = copy(output)
    malformed.index_lower = UInt64.(malformed.index_lower)
    malformed.index_lower[1] = ids[1]
    @test_throws ErrorException EuropeExample.validate_output(
        malformed, countries[6:6, :]; sources=source_fixture,
    )

    same_name = copy(mapping)
    EuropeExample.assign_labels!(same_name, DataFrame(id=ids, name=fill("Twin", 2)))
    @test count(==("Twin"), same_name.label) == 2

    monaco_id = only(ids[1:1])
    monaco_centre = api.cellToLatLng(monaco_id)
    monaco_sources = DataFrame(
        id=[monaco_id],
        x=[rad2deg(monaco_centre.lng)],
        y=[rad2deg(monaco_centre.lat)],
        value=[1.0],
        country_code=[492],
    )
    monaco = EuropeExample.fit_europe(
        countries[41:41, :], monaco_sources; backend=KA.CPU(),
    )
    @test nrow(monaco) == 1
    @test only(monaco.code) == 492
    EuropeExample.assign_labels!(monaco, DataFrame(id=[monaco_id], name=["Monaco"]))
    @test only(monaco.label) == "Monaco"
    EuropeExample.validate_output(
        EuropeExample.hilo_output(monaco), countries[41:41, :];
        sources=monaco_sources, factor=1,
    )
    subdivided_monaco = EuropeExample.load_cartogram(492; factor=2)
    @test sort(unique(subdivided_monaco.x)) == [891, 893]
    @test sort(unique(subdivided_monaco.y)) == [503, 505]

    mktempdir() do directory
        source_path = joinpath(directory, "sources.arrow")
        centres = api.cellToLatLng.(ids)
        Arrow.write(source_path, DataFrame(
            id=ids,
            population=[10.0, 20.0],
            x=[rad2deg(centre.lng) for centre in centres],
            y=[rad2deg(centre.lat) for centre in centres],
            country_code=fill(249, 2),
            ambiguous_rows=zeros(UInt64, 2),
            ambiguous_population=zeros(2),
        ))
        sources = EuropeExample.load_sources(source_path; countries=countries[6:6, :])
        @test propertynames(sources) == [:id, :x, :y, :value, :country_code]
        @test sources.id == ids
    end
end
