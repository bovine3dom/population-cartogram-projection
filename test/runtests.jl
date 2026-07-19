using AMDGPU
using CSV
using CUDA
using DataFrames
using H3
using PopulationCartogramProjection
using SHA
using TOML
using Test
using oneAPI

if Sys.isapple() && Sys.ARCH === :aarch64
    @eval using Metal
end

const FIXTURE_PATH = joinpath(@__DIR__, "fixtures", "synthetic_sources.csv")

include(joinpath(@__DIR__, "..", "examples", "regional_centres.jl"))
include(joinpath(@__DIR__, "..", "examples", "france", "iris_population.jl"))

function transport_plan(result, cost)
    return exp.((result.alpha .+ result.beta' .- cost) ./ result.eta)
end

function check_numerical_solver(backend)
    solver(args...; kwargs...) = solve_sinkhorn(args...; backend, kwargs...)
    one = solver(
        zeros(Float32, 1, 1),
        Float32[1],
        Float32[1];
        eta_schedule=Float32[0.1],
    )
    @test one.converged
    @test one.stop_reason == :converged

    cost = Float32[0 1 2; 1 0 1]
    source_mass = Float32[0.4, 0.6]
    target_mass = Float32[0.2, 0.3, 0.5]
    result = solver(
        cost,
        source_mass,
        target_mass;
        eta_schedule=Float32[0.5, 0.2, 0.1],
        max_iters_per_eta=2_000,
        tol=1e-5,
        check_every=10,
    )
    plan = transport_plan(result, cost)
    @test result.converged
    @test vec(sum(plan; dims=2)) ≈ source_mass atol=1e-4
    @test vec(sum(plan; dims=1)) ≈ target_mass atol=1e-4
    @test result.beta[end] == 0

    symmetric_cost = Float32[0 1; 1 0]
    symmetric_result = solver(
        symmetric_cost,
        Float32[0.5, 0.5],
        Float32[0.5, 0.5];
        eta_schedule=Float32[0.5],
        tol=1e-5,
    )
    symmetric_plan = transport_plan(symmetric_result, symmetric_cost)
    off_diagonal_ratio = exp(-2.0f0)
    diagonal_mass = 0.5f0 / (1 + off_diagonal_ratio)
    off_diagonal_mass = 0.5f0 - diagonal_mass
    @test symmetric_plan ≈ Float32[
        diagonal_mass off_diagonal_mass
        off_diagonal_mass diagonal_mass
    ] atol=1e-4

    asymmetric_cost = Float32[0 0.2; 0.4 0.1]
    asymmetric_source_mass = Float32[0.7, 0.3]
    asymmetric_target_mass = Float32[0.2, 0.8]
    asymmetric_result = solver(
        asymmetric_cost,
        asymmetric_source_mass,
        asymmetric_target_mass;
        eta_schedule=Float32[0.4, 0.2],
        max_iters_per_eta=2_000,
        tol=1e-5,
        check_every=10,
    )
    asymmetric_plan = transport_plan(asymmetric_result, asymmetric_cost)
    @test asymmetric_result.converged
    @test asymmetric_plan ≈ Float32[
        0.19103342 0.50896657
        0.00896658 0.29103342
    ] atol=1e-4
    @test vec(sum(asymmetric_plan; dims=2)) ≈ asymmetric_source_mass atol=1e-4
    @test vec(sum(asymmetric_plan; dims=1)) ≈ asymmetric_target_mass atol=1e-4

    limited_result = solver(
        Float32[0 4; 4 0],
        Float32[0.9, 0.1],
        Float32[0.1, 0.9];
        eta_schedule=Float32[0.01],
        max_iters_per_eta=1,
        tol=2e-6,
        check_every=1,
    )
    @test !limited_result.converged
    @test limited_result.stop_reason == :max_iterations
    @test limited_result.iterations == 1

    large_count = 257
    large_cost = reshape(
        Float32.(mod.(0:(large_count^2 - 1), 113)) ./ 112,
        large_count,
        large_count,
    )
    large_source_mass = Float32.(1:large_count)
    large_source_mass ./= sum(large_source_mass)
    large_target_mass = reverse(large_source_mass)
    large_result = solver(
        large_cost,
        large_source_mass,
        large_target_mass;
        eta_schedule=Float32[0.1],
        max_iters_per_eta=1_000,
        tol=1e-5,
        check_every=10,
    )
    large_plan = transport_plan(large_result, large_cost)
    @test large_result.converged
    @test isfinite(large_result.marginal_error)
    @test vec(sum(large_plan; dims=2)) ≈ large_source_mass atol=1e-4
    @test vec(sum(large_plan; dims=1)) ≈ large_target_mass atol=1e-4
end

function check_regional_mapping(backend)
    sources = CSV.read(FIXTURE_PATH, DataFrame)
    fitted = fit_mapping(sources; backend)
    mapping = fitted.mapping
    share_totals = combine(groupby(mapping, :id), :source_share => sum => :share)
    @test fitted isa MappingFit
    @test fitted.metadata.fit_mode == :fixed
    @test fitted.metadata.mapping_rows == nrow(mapping)
    @test all(abs.(fitted.source_retention.dropped_share) .< 1e-6)
    @test propertynames(mapping) == [:id, :country_code, :cell_id, :source_share]
    @test nrow(mapping) == nrow(sources) * 72
    @test Set(mapping.id) == Set(sources.id)
    @test all(isfinite, mapping.source_share)
    @test all(value -> isapprox(value, 1; atol=1e-4), share_totals.share)

    weighted = leftjoin(mapping, sources[:, [:id, :country_code, :population]]; on=[:id, :country_code])
    weighted.transport_mass = weighted.source_share .* weighted.population
    target_totals = combine(groupby(weighted, :cell_id), :transport_mass => sum => :mass)
    expected_mass = sum(sources.population) / nrow(target_totals)
    @test all(value -> isapprox(value, expected_mass; rtol=2e-4), target_totals.mass)
end

function check_automatic_eta(backend)
    sources = DataFrame(
        id=["north", "south"],
        population=Float32[1, 1],
        x=Float64[0, 0],
        y=Float64[60, 50],
        country_code=[999, 999],
    )
    grid = DataFrame(
        cell_id=["top", "bottom"],
        grid_x=[0, 0],
        grid_y=[0, 2],
        country_code=[999, 999],
    )
    fitted = fit_mapping_auto(
        sources,
        grid;
        backend,
        candidate_final_etas=Float32[0.5, 0.1, 0.05],
        base_eta_schedule=Float32[0.5, 0.1, 0.05],
        target_rows_multiplier=0.5,
        cumulative_share=0.995,
        max_iters_per_eta=100,
        tol=1e-5,
        check_every=5,
    )
    @test fitted.metadata.final_eta == 0.1f0
    @test fitted.metadata.selected_eta == fitted.metadata.final_eta
    @test fitted.metadata.selected_stop_reason == :converged
    @test fitted.metadata.solver_final_eta == fitted.metadata.final_eta
    @test fitted.metadata.solver_stop_reason == :stage_observer
    @test fitted.metadata.rows == fitted.metadata.target_rows == 2
    @test fitted.metadata.row_error == minimum(candidate.row_error for candidate in fitted.metadata.candidates)
    @test fitted.metadata.dropped_mass_share ≈ 1 - fitted.metadata.retained_mass_share
    @test fitted.metadata.minimum_retained_mass_share == 0
    @test all(candidate.retention_eligible for candidate in fitted.metadata.candidates)
    @test fitted.metadata.spatial_transform.method == "source_extrema"
    @test fitted.metadata.spatial_transform.longitude_bounds == (0.0, 0.0)
    @test fitted.metadata.spatial_transform.latitude_bounds == (50.0, 60.0)
    @test propertynames(fitted.mapping) == [:id, :country_code, :cell_id, :source_share]
    @test fitted.mapping.cell_id == ["top", "bottom"]
    @test propertynames(fitted.source_retention) == [
        :id,
        :country_code,
        :neighbors,
        :retained_share,
        :dropped_share,
        :cumulative_achieved,
        :truncation_reason,
    ]
    @test fitted.source_retention.neighbors == [1, 1]
    @test all(fitted.source_retention.cumulative_achieved)
    @test all(==(:cumulative_share), fitted.source_retention.truncation_reason)
    @test fitted.source_retention.retained_share ≈ combine(
        groupby(fitted.mapping, :id),
        :source_share => sum => :retained_share,
    ).retained_share
end

function check_unavailable_backend(backend, message)
    sources = CSV.read(FIXTURE_PATH, DataFrame)
    grid = load_owid_grid()
    solver_error = try
        solve_sinkhorn(
            zeros(Float32, 1, 1),
            Float32[1],
            Float32[1];
            backend,
        )
    catch error
        error
    end
    mapping_error = try
        fit_mapping(sources, grid; backend)
    catch error
        error
    end
    @test solver_error isa ArgumentError
    @test mapping_error isa ArgumentError
    @test occursin(message, sprint(showerror, solver_error))
    @test occursin(message, sprint(showerror, mapping_error))
end

@testset "source validation" begin
    sources = CSV.read(FIXTURE_PATH, DataFrame)
    @test isnothing(validate_sources(sources))
    @test_throws UndefKeywordError fit_mapping(sources)
    @test_throws UndefKeywordError fit_mapping_auto(sources)
    @test_throws ArgumentError validate_sources(select(sources, Not(:population)))

    duplicate = vcat(sources, sources[1:1, :])
    @test_throws ArgumentError validate_sources(duplicate)

    invalid_population = copy(sources)
    invalid_population.population[1] = 0
    @test_throws ArgumentError validate_sources(invalid_population)

    boolean_population = copy(sources)
    boolean_population.population = trues(nrow(boolean_population))
    @test_throws ArgumentError validate_sources(boolean_population)

    invalid_longitude = copy(sources)
    invalid_longitude.x[1] = 181
    @test_throws ArgumentError validate_sources(invalid_longitude)

    raw = DataFrame(
        index=["010010000", "2A0040101"],
        weight=[10.0, 20.0],
        longitude=[4.9, 8.7],
        latitude=[46.1, 41.9],
        label=["A", "B"],
    )
    canonical = canonicalize_sources(
        raw;
        id=:index,
        population=:weight,
        x=:longitude,
        y=:latitude,
        country_code=250,
    )
    @test propertynames(canonical) == [
        :id, :population, :x, :y, :country_code, :label,
    ]
    @test canonical.id == raw.index
    @test canonical.country_code == [250, 250]
    @test canonical.label == raw.label
    @test propertynames(raw) == [:index, :weight, :longitude, :latitude, :label]
    @test_throws ArgumentError canonicalize_sources(
        raw;
        id=:index,
        population=:weight,
        x=:longitude,
        y=:latitude,
        country_code=true,
    )
    conflicting = copy(raw)
    conflicting.id = ["old-a", "old-b"]
    @test_throws ArgumentError canonicalize_sources(
        conflicting;
        id=:index,
        population=:weight,
        x=:longitude,
        y=:latitude,
        country_code=250,
    )
end

@testset "OWID grid" begin
    grid = load_owid_grid()
    @test nrow(grid) == 54_978
    @test propertynames(grid) == [:cell_id, :grid_x, :grid_y, :country_code]
    @test allunique(grid.cell_id)
    @test count(==(56), grid.country_code) == 72
    france = load_owid_grid(; country_code=250)
    @test nrow(france) == 438
    @test all(==(250), france.country_code)
    @test_throws ArgumentError load_owid_grid(; country_code=999)
    turkey_cell = findfirst(
        (grid.country_code .== 792) .& (grid.grid_x .== 552) .& (grid.grid_y .== 262),
    )
    @test grid.cell_id[turkey_cell] == "792:552:262"
end

@testset "OWID grid subdivision" begin
    grid = DataFrame(
        cell_id=["a", "b", "c", "d"],
        grid_x=[0, 0, 2, 2],
        grid_y=[0, 2, 0, 2],
        country_code=fill(1, 4),
    )
    original = copy(grid)
    subdivided = subdivide_grid(grid; factor=2)
    @test propertynames(subdivided) == [
        :cell_id, :parent_cell_id, :grid_x, :grid_y, :country_code,
    ]
    @test nrow(subdivided) == 16
    @test subdivided.parent_cell_id[1:4] == fill("a", 4)
    @test subdivided.cell_id[1:4] == [
        "a:sub2:1:1", "a:sub2:1:2", "a:sub2:2:1", "a:sub2:2:2",
    ]
    @test subdivided.grid_x[1:4] == [-1, -1, 1, 1]
    @test subdivided.grid_y[1:4] == [-1, 1, -1, 1]
    @test allunique(subdivided.cell_id)
    @test isequal(grid, original)

    nearest = subdivide_grid(grid; target_cells=35)
    @test nrow(nearest) == 36
    @test all(==(9), combine(groupby(nearest, :parent_cell_id), nrow => :children).children)
    identity = subdivide_grid(grid; factor=1)
    @test identity.cell_id == identity.parent_cell_id == grid.cell_id

    source = DataFrame(
        id=["source"], population=[1.0], x=[0.0], y=[0.0], country_code=[1],
    )
    problem = PopulationCartogramProjection._prepare_problem(source, subdivided)
    parent_mass = combine(
        groupby(DataFrame(parent=subdivided.parent_cell_id, mass=problem.target_mass), :parent),
        :mass => sum => :mass,
    )
    @test all(mass -> isapprox(mass, 0.25; atol=eps(Float32)), parent_mass.mass)
    @test_throws ArgumentError subdivide_grid(grid)
    @test_throws ArgumentError subdivide_grid(grid; factor=2, target_cells=16)
    @test_throws ArgumentError subdivide_grid(grid; factor=0)
    @test_throws ArgumentError subdivide_grid(grid; factor=big(typemax(Int)) + 1)
    @test_throws OverflowError subdivide_grid(grid; factor=isqrt(typemax(Int)) + 1)

    planned = plan_mapping(source, grid; factor=2)
    @test planned isa MappingPlan
    @test nrow(planned.grid) == 16
    @test planned.metadata.subdivision_factor == 2
    @test planned.metadata.cost_entries == 16
    @test planned.metadata.matrix_bytes == 64
    @test planned.metadata.combined_dense_bytes ==
          planned.metadata.host_dense_bytes + planned.metadata.backend_dense_bytes
    approximate = plan_mapping(source, grid; target_cells=35)
    @test nrow(approximate.grid) == 36
    ratio_plan = plan_mapping(source, grid; sources_per_target=0.03)
    @test nrow(ratio_plan.grid) == 36
    @test nrow(plan_mapping(source, grid; sources_per_target=0.125).grid) == 16
    budgeted = plan_mapping(
        source,
        grid;
        max_backend_bytes=planned.metadata.backend_dense_bytes,
    )
    @test budgeted.metadata.subdivision_factor == 2
    @test_throws ArgumentError plan_mapping(source, grid; max_host_bytes=1)
    @test_throws ArgumentError plan_mapping(
        source, grid; max_host_bytes=big(typemax(Int)) + 1,
    )
    @test_throws ArgumentError plan_mapping(
        source, grid; sources_per_target=nextfloat(0.0),
    )
    @test_throws ArgumentError plan_mapping(source, grid; factor=2, target_cells=16)
end

@testset "per-run spatial scaling" begin
    sources = DataFrame(
        id=["west", "centre", "east"],
        population=[2.0, 3.0, 5.0],
        x=[-2.0, 0.0, 5.0],
        y=[50.0, 52.0, 51.0],
        country_code=[999, 999, 999],
    )
    grid = DataFrame(
        cell_id=["a", "b", "c", "d"],
        grid_x=[0, 2, 4, 0],
        grid_y=[0, 0, 2, 2],
        country_code=[999, 999, 999, 999],
    )

    function previous_cost(sources, targets; cost_power=2)
        function scale(values, target_values)
            source_min, source_max = extrema(values)
            target_min, target_max = extrema(target_values)
            source_min == source_max &&
                return fill((target_min + target_max) / 2, length(values))
            return target_min .+ (values .- source_min) .*
                                 ((target_max - target_min) / (source_max - source_min))
        end
        source_x = scale(Float64.(sources.x), Float64.(targets.grid_x))
        source_y = scale(-Float64.(sources.y), Float64.(targets.grid_y))
        step_x = minimum(diff(sort(unique(Float64.(targets.grid_x)))))
        step_y = minimum(diff(sort(unique(Float64.(targets.grid_y)))))
        cost = Matrix{Float32}(undef, nrow(sources), nrow(targets))
        for j in 1:nrow(targets), i in 1:nrow(sources)
            dx = (source_x[i] - targets.grid_x[j]) / step_x
            dy = (source_y[i] - targets.grid_y[j]) / step_y
            cost[i, j] = Float32(hypot(dx, dy))
        end
        max_distance = maximum(cost)
        max_distance > 0 && (cost .= (cost ./ max_distance) .^ cost_power)
        return cost
    end

    prepared = PopulationCartogramProjection._prepare_problem(sources, grid)
    @test isequal(prepared.cost, previous_cost(sources, grid))

    metadata = prepared.spatial_metadata
    @test metadata.method == "source_extrema"
    @test metadata.longitude_bounds == (-2.0, 5.0)
    @test metadata.latitude_bounds == (50.0, 52.0)
    @test metadata.grid_x_bounds == (0.0, 4.0)
    @test metadata.grid_y_bounds == (0.0, 2.0)
    @test metadata.grid_step == (2.0, 2.0)
    @test metadata.distance_scale > 0
    @test metadata.cost_power == 2.0

    expanded = vcat(sources, DataFrame(
        id=["outlier"],
        population=[1.0],
        x=[40.0],
        y=[10.0],
        country_code=[999],
    ))
    expanded_prepared = PopulationCartogramProjection._prepare_problem(expanded, grid)
    @test expanded_prepared.spatial_metadata.longitude_bounds == (-2.0, 40.0)
    @test expanded_prepared.spatial_metadata.latitude_bounds == (10.0, 52.0)
    @test !isequal(prepared.cost, expanded_prepared.cost[1:nrow(sources), :])

    order = [3, 1, 2]
    permuted = sources[order, :]
    @test isequal(
        prepared.cost[order, :],
        PopulationCartogramProjection._prepare_problem(permuted, grid).cost,
    )
    with_extra_column = copy(sources)
    with_extra_column.unrelated = [3, 2, 1]
    @test isequal(
        prepared.cost,
        PopulationCartogramProjection._prepare_problem(with_extra_column, grid).cost,
    )
    target_order = [4, 2, 1, 3]
    @test isequal(
        prepared.cost[:, target_order],
        PopulationCartogramProjection._prepare_problem(
            sources, grid[target_order, :],
        ).cost,
    )

    one_source = sources[1:1, :]
    one_problem = PopulationCartogramProjection._prepare_problem(one_source, grid)
    @test all(isfinite, one_problem.cost)
    @test only(unique(one_source.x)) == one_problem.spatial_metadata.longitude_bounds[1]
    @test only(unique(one_source.y)) == one_problem.spatial_metadata.latitude_bounds[1]

    coincident_x = copy(sources)
    coincident_x.x .= 1.0
    coincident_problem = PopulationCartogramProjection._prepare_problem(coincident_x, grid)
    @test all(isfinite, coincident_problem.cost)
    @test coincident_problem.spatial_metadata.longitude_bounds == (1.0, 1.0)

    one_cell_grid = grid[1:1, :]
    zero_problem = PopulationCartogramProjection._prepare_problem(one_source, one_cell_grid)
    @test iszero(zero_problem.spatial_metadata.distance_scale)
    @test all(iszero, zero_problem.cost)
    @test_throws ArgumentError PopulationCartogramProjection._prepare_problem(
        sources, grid; cost_power=0,
    )
end

@testset "project source values" begin
    grid = DataFrame(
        cell_id=["1:a", "1:b", "1:empty", "2:a", "2:empty"],
        grid_x=[0, 1, 2, 0, 1],
        grid_y=[0, 0, 0, 1, 1],
        country_code=[1, 1, 1, 2, 2],
    )
    values = DataFrame(
        id=["shared", "other", "shared"],
        country_code=[1, 1, 2],
        population=[100.0, 300.0, 50.0],
        households=[10.0, 20.0, 7.0],
        rate=[2.0, 4.0, 8.0],
        exposure=[50.0, 10.0, 0.0],
    )
    mapping = DataFrame(
        id=["shared", "shared", "other", "shared"],
        country_code=[1, 1, 1, 2],
        cell_id=["1:a", "1:b", "1:a", "2:a"],
        source_share=[0.6, 0.2, 0.5, 0.75],
    )
    original_values = copy(values)
    original_mapping = copy(mapping)

    extensive = project_extensive(mapping, values, grid; value=:households)
    @test propertynames(extensive.cells) == [
        :cell_id, :grid_x, :grid_y, :country_code, :households,
    ]
    @test extensive.cells.cell_id == grid.cell_id
    @test extensive.cells.households == [16.0, 2.0, 0.0, 5.25, 0.0]
    @test extensive.source_retention.neighbors == [2, 1, 1]
    @test extensive.source_retention.retained_share ≈ [0.8, 0.5, 0.75]
    @test extensive.source_retention.dropped_share ≈ [0.2, 0.5, 0.25]
    @test extensive.metadata.input_total == 37.0
    @test extensive.metadata.projected_total == 23.25
    @test extensive.metadata.dropped_total == 13.75
    @test extensive.metadata.weighted_retained_share ≈ 23.25 / 37

    intensive = project_intensive(mapping, values, grid; value=:rate)
    @test propertynames(intensive.cells) == [
        :cell_id, :grid_x, :grid_y, :country_code, :projected_population, :rate,
    ]
    @test intensive.cells.projected_population == [210.0, 20.0, 0.0, 37.5, 0.0]
    @test intensive.cells.rate[1] ≈ 24 / 7
    @test intensive.cells.rate[2] == 2.0
    @test ismissing(intensive.cells.rate[3])
    @test intensive.cells.rate[4] == 8.0
    @test ismissing(intensive.cells.rate[5])
    @test intensive.metadata.input_population == 450.0
    @test intensive.metadata.projected_population == 267.5
    @test intensive.metadata.dropped_population == 182.5
    @test intensive.metadata.zero_population_cells == 2

    ratio = project_ratio(
        mapping,
        values,
        grid;
        value=:rate,
        weight=:exposure,
        denominator=:projected_exposure,
        minimum_source_retained_share=0.5,
        minimum_weighted_retained_share=0.75,
    )
    @test ratio.cells.projected_exposure == [35.0, 10.0, 0.0, 0.0, 0.0]
    @test ratio.cells.rate[1] ≈ 16 / 7
    @test ratio.cells.rate[2] == 2
    @test all(ismissing, ratio.cells.rate[[3, 4, 5]])
    @test ratio.metadata.weighted_retained_share == 0.75
    @test_throws ArgumentError project_ratio(
        mapping,
        values,
        grid;
        value=:rate,
        weight=:exposure,
        minimum_source_retained_share=0.51,
    )
    @test_throws ArgumentError project_ratio(
        mapping,
        values,
        grid;
        value=:rate,
        weight=:exposure,
        minimum_weighted_retained_share=0.76,
    )

    signed = copy(values)
    signed.balance = [10.0, -10.0, 0.0]
    signed_projection = project_extensive(mapping, signed, grid; value=:balance)
    @test signed_projection.metadata.input_total == 0
    @test signed_projection.metadata.input_absolute_total == 20
    @test signed_projection.metadata.weighted_retained_share == 0.65

    custom_retention = project_extensive(
        mapping, values, grid; value=:households, retention_weight=:exposure,
    )
    @test custom_retention.metadata.input_absolute_total == 37
    @test custom_retention.metadata.projected_absolute_source_total == 23.25
    @test custom_retention.metadata.input_retention_weight == 60
    @test custom_retention.metadata.projected_retention_weight == 45

    population = project_extensive(mapping, values, grid; value=:population)
    @test population.cells.population == intensive.cells.projected_population
    @test isequal(values, original_values)
    @test isequal(mapping, original_mapping)

    duplicate_values = vcat(values, values[1:1, :])
    @test_throws ArgumentError project_extensive(
        mapping, duplicate_values, grid; value=:households,
    )
    @test_throws ArgumentError project_extensive(
        vcat(mapping, mapping[1:1, :]), values, grid; value=:households,
    )
    @test_throws ArgumentError project_extensive(
        mapping, values[1:2, :], grid; value=:households,
    )

    wrong_country_cell = copy(mapping)
    wrong_country_cell.cell_id[4] = "1:a"
    @test_throws ArgumentError project_extensive(
        wrong_country_cell, values, grid; value=:households,
    )
    excessive_share = copy(mapping)
    excessive_share.source_share[2] = 0.5
    @test_throws ArgumentError project_extensive(
        excessive_share, values, grid; value=:households,
    )
    invalid_values = copy(values)
    invalid_values.households[1] = Inf
    @test_throws ArgumentError project_extensive(
        mapping, invalid_values, grid; value=:households,
    )
    invalid_population = copy(values)
    invalid_population.population[1] = 0
    @test_throws ArgumentError project_intensive(
        mapping, invalid_population, grid; value=:rate,
    )
    @test_throws ArgumentError project_intensive(mapping, values, grid; value=:population)
    invalid_weight = copy(values)
    invalid_weight.exposure[1] = -1
    @test_throws ArgumentError project_ratio(
        mapping, invalid_weight, grid; value=:rate, weight=:exposure,
    )

    overflowing = copy(values)
    overflowing.households[1:2] .= floatmax(Float64)
    @test_throws ArgumentError project_extensive(
        mapping, overflowing, grid; value=:households,
    )
    overflowing.exposure[1:2] .= floatmax(Float64)
    @test_throws ArgumentError project_ratio(
        mapping, overflowing, grid; value=:rate, weight=:exposure,
    )

    tolerance_values = DataFrame(id=["one"], country_code=[1], value=[10.0], weight=[2.0])
    tolerance_grid = grid[1:2, :]
    for (shares, expected) in (([0.5, 0.4999995], 9.999995), ([0.5, 0.5000005], 10.0))
        tolerance_mapping = DataFrame(
            id=fill("one", 2),
            country_code=fill(1, 2),
            cell_id=tolerance_grid.cell_id,
            source_share=shares,
        )
        projected = project_extensive(
            tolerance_mapping, tolerance_values, tolerance_grid; value=:value,
        )
        @test sum(projected.cells.value) ≈ expected
        ratio_at_tolerance = project_ratio(
            tolerance_mapping,
            tolerance_values,
            tolerance_grid;
            value=:value,
            weight=:weight,
        )
        @test ratio_at_tolerance.metadata.dropped_weight ≈ 2 * (1 - expected / 10)
        @test ratio_at_tolerance.metadata.dropped_weight_share ≈ 1 - expected / 10
    end
end

@testset "country reconciliation and fitting" begin
    sources = DataFrame(
        id=["shared", "shared", "unmatched"],
        population=[1.0, 2.0, 3.0],
        x=[0.0, 10.0, 20.0],
        y=[1.0, 2.0, 3.0],
        country_code=[1, 2, 99],
        value=[10.0, 20.0, 30.0],
    )
    grid = DataFrame(
        cell_id=["1:a", "2:a"],
        grid_x=[0, 0],
        grid_y=[0, 0],
        country_code=[1, 2],
    )
    reconciled = reconcile_countries(sources, grid)
    @test reconciled.statuses.status == [:included, :included, :skipped]
    @test nrow(reconciled.sources) == 2
    @test reconciled.metadata.skipped_sources == 1
    all_skipped = reconcile_countries(sources[3:3, :], grid)
    @test nrow(all_skipped.sources) == 0
    @test all_skipped.metadata.retained_population == 0
    zero_sources = copy(sources[1:1, :])
    zero_sources.country_code .= 0
    zero_grid = DataFrame(cell_id=["0:a"], grid_x=[0], grid_y=[0], country_code=[0])
    @test only(reconcile_countries(zero_sources, zero_grid).statuses.status) == :included
    remap_sources = sources[[1, 3], :]
    remapped = reconcile_countries(remap_sources, grid; crosswalk=Dict(99 => 2))
    @test remapped.statuses.status == [:included, :remapped]
    @test_throws ArgumentError reconcile_countries(sources, grid; crosswalk=Dict(99 => 3))
    @test_throws ArgumentError reconcile_countries(sources, grid; crosswalk=Dict(99 => 1))

    options = (
        candidate_final_etas=Float32[0.5],
        base_eta_schedule=Float32[0.5],
        target_rows_multiplier=1.0,
        max_iters_per_eta=10,
        tol=0.1,
        check_every=1,
    )
    caught = try
        fit_mapping_countries(sources, grid; backend=:cpu, options...)
        nothing
    catch error
        error
    end
    @test caught isa IncompleteCountryFitError
    @test caught.result.country_statuses.status == [:included, :included, :skipped]
    partial = fit_mapping_countries(
        sources,
        grid;
        backend=:cpu,
        allow_partial=true,
        options...,
    )
    @test nrow(partial.mapping) == 2
    @test nrow(partial.sources) == 2
    @test partial.metadata.successful_countries == 2
    projected = project_extensive(partial.mapping, partial.sources, grid; value=:value)
    @test projected.cells.value == [10.0, 20.0]

    fitted = fit_mapping_countries(
        remap_sources,
        grid;
        backend=:cpu,
        crosswalk=Dict(99 => 2),
        options...,
    )
    @test fitted.country_statuses.status == [:included, :remapped]
    @test Set(fitted.mapping.country_code) == Set([1, 2])
    mktempdir() do output_dir
        paths = save_fit(output_dir, fitted; grid)
        metadata = TOML.parsefile(paths.metadata)
        @test metadata["schema"] == "PopulationCartogramProjection.MultiCountryFit"
        @test metadata["country_statuses_sha256"] ==
              bytes2hex(open(SHA.sha256, paths.country_statuses))
    end

    invalid = copy(sources[[1, 2], :])
    invalid.population[2] = 0
    failed = fit_mapping_countries(
        invalid,
        grid;
        backend=:cpu,
        allow_partial=true,
        options...,
    )
    @test failed.country_statuses.status == [:included, :failed]
    @test failed.sources.country_code == [1]
    @test failed.mapping.country_code == [1]
    @test failed.source_retention.country_code == [1]
    @test collect(keys(failed.country_fits)) == [1]
    @test failed.metadata.successful_sources == 1
    @test_throws IncompleteCountryFitError fit_mapping_countries(
        invalid[2:2, :],
        grid;
        backend=:cpu,
        allow_partial=true,
        options...,
    )
end

@testset "H3 source adapter" begin
    api = H3.API
    parent = api.latLngToCell(api.LatLng(deg2rad(51.5), deg2rad(-0.1)), 5)
    @test !(parent isa H3.API.H3ErrorCode)
    children = api.cellToChildren(parent, 6)
    @test !(children isa H3.API.H3ErrorCode)
    raw = DataFrame(h3=children[1:2], people=[10.0, 20.0], code=[826, 826])
    original = copy(raw)

    native = canonicalize_h3_sources(
        raw;
        id=:h3,
        population=:people,
        country_code=:code,
    )
    @test eltype(native.id) == UInt64
    @test native.id == raw.h3
    @test all(==(6), Int.(api.getResolution.(native.id)))
    @test all(==(826), native.country_code)
    @test isnothing(validate_sources(native))

    aggregated = canonicalize_h3_sources(
        raw;
        id=:h3,
        population=:people,
        country_code=826,
        resolution=5,
    )
    @test nrow(aggregated) == 1
    @test only(aggregated.id) == parent
    @test only(aggregated.population) == 30
    centre = api.cellToLatLng(parent)
    @test only(aggregated.x) ≈ rad2deg(centre.lng)
    @test only(aggregated.y) ≈ rad2deg(centre.lat)
    @test isequal(raw, original)

    large_integer_population = copy(raw)
    large_integer_population.people .= typemax(Int)
    large_aggregate = canonicalize_h3_sources(
        large_integer_population;
        id=:h3,
        population=:people,
        country_code=826,
        resolution=5,
    )
    @test only(large_aggregate.population) == 2 * Float64(typemax(Int))
    unrepresentable = copy(raw[1:1, :])
    unrepresentable.people = BigFloat[big"1e400"]
    @test_throws ArgumentError canonicalize_h3_sources(
        unrepresentable; id=:h3, population=:people, country_code=826,
    )

    @test_throws ArgumentError canonicalize_h3_sources(
        DataFrame(h3=UInt64[0], population=[1.0]); country_code=826,
    )
    @test_throws ArgumentError canonicalize_h3_sources(
        raw; id=:h3, population=:people, country_code=826, resolution=7,
    )
    @test_throws ArgumentError canonicalize_h3_sources(
        raw; id=:h3, population=:h3, country_code=826,
    )
    mixed = DataFrame(h3=UInt64[children[1], parent], population=[1.0, 1.0])
    @test_throws ArgumentError canonicalize_h3_sources(mixed; country_code=826)
end

@testset "dominant source assignment" begin
    sources = DataFrame(
        id=["large", "small"],
        population=[100.0, 10.0],
        x=[1.0, 2.0],
        y=[45.0, 46.0],
        country_code=[1, 1],
    )
    mapping = DataFrame(
        id=["large", "large", "large", "small", "small"],
        country_code=[1, 1, 1, 1, 1],
        cell_id=["a", "b", "empty", "a", "b"],
        source_share=[0.2, 0.8, 0.0, 0.9, 0.1],
    )
    grid = DataFrame(
        cell_id=["a", "b", "empty"],
        parent_cell_id=["parent-a", "parent-b", "parent-empty"],
        grid_x=[0, 2, 4],
        grid_y=[0, 0, 0],
        country_code=[1, 1, 1],
    )
    assignment = dominant_source_assignment(mapping, sources, grid)
    @test assignment.parent_cell_id == grid.parent_cell_id
    @test isequal(assignment.id, ["large", "large", missing])
    @test assignment.transport_mass == [20.0, 80.0, 0.0]
    @test assignment.cell_transport_mass == [29.0, 81.0, 0.0]
    @test assignment.transport_share[1] ≈ 20 / 29
    @test assignment.transport_share[2] ≈ 80 / 81
    @test ismissing(assignment.transport_share[3])

    grid_with_metadata = copy(grid)
    grid_with_metadata.population = [1.0, 1.0, 1.0]
    @test dominant_source_assignment(mapping, sources, grid_with_metadata).population ==
          grid_with_metadata.population

    labels = DataFrame(
        id=["large", "small", "large"],
        country_code=[1, 1, 1],
        name=["Paris", "Nice", "Lyon"],
    )
    placed = place_source_labels(mapping, labels, grid)
    @test isequal(placed.cells.label, ["Nice", "Paris, Lyon", missing])
    @test placed.placements.cell_id == ["b", "a", "b"]
    @test placed.placements.grid_x == [2.0, 0.0, 2.0]
    unmatched_labels = copy(labels)
    unmatched_labels.id[1] = "unknown"
    @test_throws ArgumentError place_source_labels(mapping, unmatched_labels, grid)

    zero_candidate_mapping = DataFrame(
        id=fill("large", 3),
        country_code=fill(1, 3),
        cell_id=["a", "b", "empty"],
        source_share=[0.5, 0.0, 0.5],
    )
    one_label = labels[1:1, :]
    @test only(place_source_labels(zero_candidate_mapping, one_label, grid).placements.cell_id) ==
          "a"

    empty_labels = DataFrame(id=String[], country_code=Int[], name=String[])
    empty_placement = place_source_labels(mapping, empty_labels, grid)
    @test nrow(empty_placement.placements) == 0
    @test all(ismissing, empty_placement.cells.label)
    nullable_labels = vcat(
        one_label,
        DataFrame(id=["unknown"], country_code=[1], name=[missing]);
        cols=:union,
    )
    @test nrow(place_source_labels(mapping, nullable_labels, grid).placements) == 1

    huge_sources = copy(sources)
    huge_sources.population .= 1e308
    huge_mapping = DataFrame(
        id=huge_sources.id,
        country_code=huge_sources.country_code,
        cell_id=fill("a", 2),
        source_share=ones(2),
    )
    @test_throws ArgumentError dominant_source_assignment(huge_mapping, huge_sources, grid)

    projected = project_extensive(mapping, sources, grid; value=:population)
    @test projected.cells.parent_cell_id == grid.parent_cell_id
end

@testset "France IRIS source example" begin
    (; sources, report) = FranceIrisExample.load_sources()
    @test report.input_rows == 49_276
    @test report.included_rows == nrow(sources) == 48_416
    @test report.missing_coordinate_rows == 708
    @test report.nonpositive_population_rows == 169
    @test report.excluded_rows == 860
    @test report.included_population ≈ 64_445_214.56572973 rtol=1e-12
    @test propertynames(sources) == [
        :id, :population, :x, :y, :country_code, :area_km2, :population_density,
    ]
    @test all(id -> ncodeunits(id) == 9, sources.id)
    @test any(startswith("0"), sources.id)
    @test any(startswith("2A"), sources.id)
    @test collect(extrema(sources.x)) ≈ [-5.086015483046215, 9.529000248915922]
    @test collect(extrema(sources.y)) ≈ [41.43510246152267, 51.07297146412994]
    @test all(>(0), sources.area_km2)
    @test all(>(0), sources.population_density)
    sorted_density = sort(sources.population_density)
    density_midpoint = length(sorted_density) ÷ 2
    @test (sorted_density[density_midpoint] + sorted_density[density_midpoint + 1]) / 2 ≈
          72.63624764673145

    france = load_owid_grid(; country_code=250)
    subdivided = subdivide_grid(france; target_cells=cld(nrow(sources), 10))
    @test nrow(subdivided) == 3_942
    @test nrow(sources) / nrow(subdivided) ≈ 12.28209030948757

    cities = FranceIrisExample.load_city_labels()
    @test nrow(cities) == 7
    @test Set(cities.name) == Set([
        "Paris", "Marseille", "Lyon", "Toulouse", "Nice", "Nantes", "Marne La Vallée",
    ])
    source_keys = Set(zip(sources.country_code, sources.id))
    @test all(key -> key in source_keys, zip(cities.country_code, cities.id))
end

@testset "regional CSV example" begin
    mktempdir() do output_dir
        paths = RegionalCentresExample.main([output_dir])
        @test all(isfile, Base.values(paths))

        mapping = CSV.read(paths.mapping, DataFrame)
        retention = CSV.read(paths.source_retention, DataFrame)
        households = CSV.read(paths.households, DataFrame)
        employment_rate = CSV.read(paths.employment_rate, DataFrame)
        summary = CSV.read(paths.summary, DataFrame)
        metadata = TOML.parsefile(paths.metadata)
        @test propertynames(mapping) == [:id, :country_code, :cell_id, :source_share]
        @test propertynames(retention) == [
            :id,
            :country_code,
            :neighbors,
            :retained_share,
            :dropped_share,
            :cumulative_achieved,
            :truncation_reason,
        ]
        @test propertynames(households) == [
            :cell_id, :parent_cell_id, :grid_x, :grid_y, :country_code, :households,
        ]
        @test propertynames(employment_rate) == [
            :cell_id,
            :parent_cell_id,
            :grid_x,
            :grid_y,
            :country_code,
            :projected_population,
            :employment_rate,
        ]
        @test nrow(retention) == 5
        @test nrow(households) == nrow(employment_rate) == 72
        @test sum(households.households) < sum(
            [510_000, 760_000, 1_080_000, 390_000, 310_000],
        )
        @test all(employment_rate.projected_population .> 0)
        @test summary.metric == [
            "selected_eta",
            "mapping_rows",
            "retained_population_share",
            "projected_households",
            "dropped_households",
        ]
        @test summary.value[2] == nrow(mapping)
        @test summary.value[4] ≈ sum(households.households)
        @test metadata["schema"] == "PopulationCartogramProjection.MappingFit"
        @test metadata["fit"]["fit_mode"] == "auto"
        @test metadata["mapping_sha256"] == bytes2hex(open(SHA.sha256, paths.mapping))

        note_path = joinpath(output_dir, "user-notes.txt")
        write(note_path, "keep me")
        RegionalCentresExample.publish_output(output_dir) do staged_dir
            write(joinpath(staged_dir, "additional.txt"), "new")
        end
        @test read(note_path, String) == "keep me"
        @test read(joinpath(output_dir, "additional.txt"), String) == "new"

        original = Dict(path => read(path) for path in Base.values(paths))
        invalid = MappingFit(mapping, retention, (unsupported=Ref(1),))
        @test_throws ErrorException save_fit(output_dir, invalid; overwrite=true)
        @test all(read(path) == contents for (path, contents) in original)
        failed_dir = joinpath(output_dir, "failed")
        @test_throws ErrorException save_fit(failed_dir, invalid)
        @test !ispath(failed_dir)

        replacement = MappingFit(mapping, retention, (fit_mode=:replacement,))
        save_fit(output_dir, replacement; overwrite=true)
        @test !ispath(paths.sources)
        @test !ispath(paths.grid)
    end
end

@testset "solver input validation" begin
    cost = Float32[0 1 2; 1 0 1]
    source_mass = Float32[0.4, 0.6]
    target_mass = Float32[0.2, 0.3, 0.5]
    @test_throws UndefKeywordError solve_sinkhorn(cost, source_mass, target_mass)
    @test_throws DimensionMismatch solve_sinkhorn(
        cost, Float32[1], target_mass; backend=:cpu,
    )
    @test_throws ArgumentError solve_sinkhorn(
        cost, source_mass, target_mass; backend=:cpu, eta_schedule=Float32[],
    )
    @test_throws ArgumentError solve_sinkhorn(
        cost, source_mass, target_mass; backend=:cpu, eta_schedule=[true],
    )
    @test_throws ArgumentError solve_sinkhorn(
        cost, source_mass, target_mass; backend=:cpu, tol=1e-8,
    )
    @test_throws ArgumentError solve_sinkhorn(
        cost, Float32[-0.4, 1.4], target_mass; backend=:cpu,
    )
    @test_throws ArgumentError solve_sinkhorn(cost, source_mass, target_mass; backend=:invalid)

    one_solver(; kwargs...) = solve_sinkhorn(
        zeros(Float32, 1, 1), Float32[1], Float32[1]; backend=:cpu, kwargs...,
    )
    observed_etas = Float32[]
    one_solver(
        ;
        eta_schedule=Float32[0.5, 0.1],
        stage_observer=result -> (push!(observed_etas, result.eta); false),
        stage_observer_etas=Float32[0.1],
    )
    @test observed_etas == Float32[0.1]
    @test_throws ArgumentError one_solver(
        ;
        eta_schedule=Float32[0.5],
        stage_observer_etas=Float32[0.5],
    )
    @test_throws ArgumentError one_solver(
        ;
        eta_schedule=Float32[0.5],
        stage_observer=_ -> false,
        stage_observer_etas=Float32[0.1],
    )
    @test_throws ArgumentError one_solver(
        ;
        eta_schedule=Float32[0.5],
        stage_observer=_ -> 1,
    )
end

@testset "automatic eta tuning" begin
    @test eta_schedule_to(0.003; base_schedule=Float32[0.05, 0.01, 0.005, 0.002]) ==
          Float32[0.05, 0.01, 0.005, 0.003]
    @test eta_continuation_schedule(
        Float32[0.005, 0.001, 0.005];
        base_schedule=Float32[0.05, 0.01, 0.005, 0.002],
    ) == Float32[0.05, 0.01, 0.005, 0.002, 0.001]
    @test_throws ArgumentError eta_continuation_schedule(Float32[])
    check_automatic_eta(:cpu)

    function sparse_select(
        shares=[0.6, 0.25, 0.1, 0.05];
        cumulative_share=0.8,
        minimum_source_share=0.0,
        minimum_neighbors=1,
        maximum_neighbors=nothing,
        collect_indices=false,
        tie_keys=nothing,
    )
        options = PopulationCartogramProjection._sparse_options(
            length(shares);
            cumulative_share,
            minimum_source_share,
            minimum_neighbors,
            maximum_neighbors,
        )
        return PopulationCartogramProjection._select_sparse_row(
            shares, options; collect_indices, tie_keys,
        )
    end
    cumulative = sparse_select()
    @test (cumulative.count, cumulative.cumulative_achieved, cumulative.stop_reason) ==
          (2, true, :cumulative_share)
    @test cumulative.retained_share ≈ 0.85

    threshold = sparse_select(; cumulative_share=0.99, minimum_source_share=0.2)
    @test (threshold.count, threshold.cumulative_achieved, threshold.stop_reason) ==
          (2, false, :minimum_source_share)

    minimum_count = sparse_select(
        ; cumulative_share=0.5, minimum_source_share=0.3, minimum_neighbors=2,
    )
    @test (minimum_count.count, minimum_count.stop_reason) == (2, :cumulative_share)

    capped = sparse_select(; cumulative_share=0.99, maximum_neighbors=2)
    @test (capped.count, capped.cumulative_achieved, capped.stop_reason) ==
          (2, false, :maximum_neighbors)

    nonbinding_cap = sparse_select(
        [0.6, 0.3, 0.05, 0.04]; cumulative_share=1.0, maximum_neighbors=4,
    )
    @test nonbinding_cap.stop_reason == :targets_exhausted

    numerical_zero = sparse_select(
        [0.9, 0.0, 0.0]; cumulative_share=1.0, minimum_neighbors=2,
    )
    @test (numerical_zero.count, numerical_zero.stop_reason) == (2, :numerical_zero)

    tied = sparse_select(
        [0.5, 0.5];
        cumulative_share=0.5,
        maximum_neighbors=1,
        collect_indices=true,
        tie_keys=["b", "a"],
    )
    @test tied.selected == [2]

    fallback_sources = DataFrame(
        id=["a", "b"],
        population=Float32[1, 2],
        x=[0.0, 1.0],
        y=[1.0, 0.0],
        country_code=[999, 999],
    )
    fallback_grid = DataFrame(
        cell_id=["x", "y"],
        grid_x=[0, 2],
        grid_y=[0, 1],
        country_code=[999, 999],
    )
    auto_options = (
        backend=:cpu,
        base_eta_schedule=Float32[0.5, 0.1, 0.05],
        target_rows_multiplier=0.75,
        cumulative_share=0.995,
        max_iters_per_eta=20,
        tol=1e-5,
        check_every=1,
    )
    continued = fit_mapping_auto(
        fallback_sources,
        fallback_grid;
        auto_options...,
        candidate_final_etas=Float32[0.5, 0.1, 0.05],
    )
    @test continued.metadata.selected_eta == 0.05f0
    @test continued.metadata.solver_final_converged
    @test only(continued.metadata.failed_candidates).final_eta == 0.1f0
    @test [candidate.converged for candidate in continued.metadata.candidates] == [true, false, true]

    fallback = fit_mapping_auto(
        fallback_sources,
        fallback_grid;
        auto_options...,
        candidate_final_etas=Float32[0.5, 0.1],
    )
    @test fallback.metadata.selected_eta == 0.5f0
    @test fallback.metadata.solver_final_eta == 0.1f0
    @test !fallback.metadata.solver_final_converged
    @test nrow(fallback.mapping) == fallback.metadata.rows == 4

    @test_throws PopulationCartogramProjection.MappingFitError fit_mapping_auto(
        fallback_sources,
        fallback_grid;
        auto_options...,
        candidate_final_etas=Float32[0.5, 0.1],
        max_iters_per_eta=1,
    )
    @test_throws ArgumentError fit_mapping_auto(
        fallback_sources,
        fallback_grid;
        auto_options...,
        candidate_final_etas=Float32[0.5],
        minimum_retained_mass_share=1.1,
    )
end

@testset "KernelAbstractions CPU Sinkhorn" begin
    check_numerical_solver(:cpu)
end

@testset "KernelAbstractions CPU regional mapping" begin
    check_regional_mapping(:cpu)
end

if CUDA.functional()
    @testset "KernelAbstractions CUDA Sinkhorn" begin
        check_numerical_solver(:cuda)
    end
    @testset "KernelAbstractions CUDA regional mapping" begin
        check_regional_mapping(:cuda)
    end
    @testset "KernelAbstractions CUDA automatic eta" begin
        check_automatic_eta(:cuda)
    end
else
    @testset "CUDA requirement" begin
        check_unavailable_backend(:cuda, "NVIDIA CUDA-capable GPU")
    end
end

if AMDGPU.functional() && AMDGPU.has_rocm_gpu()
    @testset "KernelAbstractions AMDGPU Sinkhorn" begin
        check_numerical_solver(:amdgpu)
    end
    @testset "KernelAbstractions AMDGPU regional mapping" begin
        check_regional_mapping(:amdgpu)
    end
    @testset "KernelAbstractions AMDGPU automatic eta" begin
        check_automatic_eta(:amdgpu)
    end
else
    @testset "AMDGPU requirement" begin
        check_unavailable_backend(:amdgpu, "supported AMD GPU")
    end
end

if PopulationCartogramProjection._optional_backend_functional(Val(:metal))
    @testset "KernelAbstractions Metal Sinkhorn" begin
        check_numerical_solver(:metal)
    end
    @testset "KernelAbstractions Metal regional mapping" begin
        check_regional_mapping(:metal)
    end
    @testset "KernelAbstractions Metal automatic eta" begin
        check_automatic_eta(:metal)
    end
else
    @testset "Metal requirement" begin
        message = PopulationCartogramProjection._optional_backend_loaded(Val(:metal)) ?
                  "Apple Silicon Mac" : "extension is not loaded"
        check_unavailable_backend(:metal, message)
    end
end

if oneAPI.functional()
    @testset "KernelAbstractions oneAPI Sinkhorn" begin
        check_numerical_solver(:oneapi)
    end
    @testset "KernelAbstractions oneAPI regional mapping" begin
        check_regional_mapping(:oneapi)
    end
    @testset "KernelAbstractions oneAPI automatic eta" begin
        check_automatic_eta(:oneapi)
    end
end
