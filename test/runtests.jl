using CSV
using CUDA
using DataFrames
using PopulationCartogramProjection
using Test
using oneAPI

const PCP = PopulationCartogramProjection
const FIXTURE_PATH = joinpath(@__DIR__, "fixtures", "synthetic_sources.csv")

function transport_plan(result, cost)
    return exp.((result.alpha .+ result.beta' .- cost) ./ result.eta)
end

function check_numerical_solver(solver)
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

    large_count = 257
    large_cost = reshape(
        Float32.(mod.(0:(large_count^2 - 1), 113)) ./ 112,
        large_count,
        large_count,
    )
    large_mass = fill(inv(Float32(large_count)), large_count)
    large_result = solver(
        large_cost,
        large_mass,
        large_mass;
        eta_schedule=Float32[0.1],
        max_iters_per_eta=1_000,
        tol=1e-5,
        check_every=10,
    )
    @test large_result.converged
    @test isfinite(large_result.marginal_error)
    return (; result, plan)
end

function check_regional_mapping(implementation)
    sources = CSV.read(FIXTURE_PATH, DataFrame)
    mapping = fit_mapping(sources; implementation)
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
    return mapping
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
end

@testset "KernelAbstractions CPU Sinkhorn" begin
    check_numerical_solver(
        (cost, source, target; kwargs...) ->
            solve_sinkhorn_ka(cost, source, target; backend=:cpu, kwargs...),
    )
end

@testset "KernelAbstractions CPU regional mapping" begin
    check_regional_mapping(:ka_cpu)
end

if CUDA.functional()
    direct_result = Ref{Any}()
    portable_result = Ref{Any}()
    @testset "direct CUDA Sinkhorn" begin
        direct_result[] = check_numerical_solver(solve_sinkhorn_cuda)
    end
    @testset "KernelAbstractions CUDA Sinkhorn" begin
        portable_result[] = check_numerical_solver(
            (cost, source, target; kwargs...) ->
                solve_sinkhorn_ka(cost, source, target; backend=:cuda, kwargs...),
        )
    end
    @testset "CUDA implementation parity" begin
        @test direct_result[].result.converged == portable_result[].result.converged
        @test direct_result[].result.eta == portable_result[].result.eta
        @test direct_result[].result.marginal_error ≈ portable_result[].result.marginal_error atol=1e-5
        @test direct_result[].plan ≈ portable_result[].plan atol=1e-4
    end
    direct_mapping = Ref{Any}()
    portable_mapping = Ref{Any}()
    @testset "direct CUDA regional mapping" begin
        direct_mapping[] = check_regional_mapping(:cuda)
    end
    @testset "KernelAbstractions CUDA regional mapping" begin
        portable_mapping[] = check_regional_mapping(:ka_cuda)
    end
    @testset "CUDA regional mapping parity" begin
        sort!(direct_mapping[], [:id, :cell_id])
        sort!(portable_mapping[], [:id, :cell_id])
        @test direct_mapping[].id == portable_mapping[].id
        @test direct_mapping[].cell_id == portable_mapping[].cell_id
        @test direct_mapping[].source_share ≈ portable_mapping[].source_share atol=1e-4
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
        check_numerical_solver(
            (cost, source, target; kwargs...) ->
                solve_sinkhorn_ka(cost, source, target; backend=:oneapi, kwargs...),
        )
    end
    @testset "KernelAbstractions oneAPI regional mapping" begin
        check_regional_mapping(:ka_oneapi)
    end
end
