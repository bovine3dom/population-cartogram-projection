using AMDGPU
using CSV
using CUDA
using DataFrames
using PopulationCartogramProjection
using Test
using oneAPI

if Sys.isapple() && Sys.ARCH === :aarch64
    @eval using Metal
end

const FIXTURE_PATH = joinpath(@__DIR__, "fixtures", "synthetic_sources.csv")

include(joinpath(@__DIR__, "..", "examples", "regional_centres.jl"))

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
    mapping = fit_mapping(sources; backend)
    share_totals = combine(groupby(mapping, :id), :source_share => sum => :share)
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
end

@testset "OWID grid" begin
    grid = load_owid_grid()
    @test nrow(grid) == 54_978
    @test propertynames(grid) == [:cell_id, :grid_x, :grid_y, :country_code]
    @test allunique(grid.cell_id)
    @test count(==(56), grid.country_code) == 72
    turkey_cell = findfirst(
        (grid.country_code .== 792) .& (grid.grid_x .== 552) .& (grid.grid_y .== 262),
    )
    @test grid.cell_id[turkey_cell] == "792:552:262"
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
            :cell_id, :grid_x, :grid_y, :country_code, :households,
        ]
        @test propertynames(employment_rate) == [
            :cell_id,
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

    @test_throws ErrorException fit_mapping_auto(
        fallback_sources,
        fallback_grid;
        auto_options...,
        candidate_final_etas=Float32[0.5, 0.1],
        max_iters_per_eta=1,
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
