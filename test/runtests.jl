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

@testset "solver input validation" begin
    cost = Float32[0 1 2; 1 0 1]
    source_mass = Float32[0.4, 0.6]
    target_mass = Float32[0.2, 0.3, 0.5]
    @test_throws DimensionMismatch solve_sinkhorn(cost, Float32[1], target_mass)
    @test_throws ArgumentError solve_sinkhorn(cost, source_mass, target_mass; eta_schedule=Float32[])
    @test_throws ArgumentError solve_sinkhorn(cost, source_mass, target_mass; eta_schedule=[true])
    @test_throws ArgumentError solve_sinkhorn(cost, source_mass, target_mass; tol=1e-8)
    @test_throws ArgumentError solve_sinkhorn(cost, Float32[-0.4, 1.4], target_mass)
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
