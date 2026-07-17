using CSV
using CUDA
using DataFrames
using PopulationCartogramProjection
using Test
using oneAPI

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
else
    @testset "CUDA requirement" begin
        sources = CSV.read(FIXTURE_PATH, DataFrame)
        grid = load_owid_grid()
        solver_error = try
            solve_sinkhorn(zeros(Float32, 1, 1), Float32[1], Float32[1])
        catch error
            error
        end
        mapping_error = try
            fit_mapping(sources, grid)
        catch error
            error
        end
        @test solver_error isa ArgumentError
        @test mapping_error isa ArgumentError
        @test occursin("NVIDIA CUDA-capable GPU", sprint(showerror, solver_error))
        @test occursin("NVIDIA CUDA-capable GPU", sprint(showerror, mapping_error))
    end
end

if oneAPI.functional()
    @testset "KernelAbstractions oneAPI Sinkhorn" begin
        check_numerical_solver(:oneapi)
    end
    @testset "KernelAbstractions oneAPI regional mapping" begin
        check_regional_mapping(:oneapi)
    end
end
