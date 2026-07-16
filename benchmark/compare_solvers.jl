using CUDA
using PopulationCartogramProjection
using Random
using Statistics
using oneAPI

source_count = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 256
target_count = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 256
repetitions = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 5

source_count > 0 || error("source count must be positive")
target_count > 0 || error("target count must be positive")
repetitions > 0 || error("repetitions must be positive")

Random.seed!(20260716)
cost = rand(Float32, source_count, target_count)
source_mass = rand(Float32, source_count)
source_mass ./= sum(source_mass)
target_mass = rand(Float32, target_count)
target_mass ./= sum(target_mass)

solver_options = (
    eta_schedule=Float32[0.05, 0.02, 0.01],
    max_iters_per_eta=500,
    tol=1e-5,
    check_every=25,
)

function benchmark_solver(solver, name)
    print("Warming $name ... ")
    warm_result = solver()
    println("$(warm_result.iterations) iterations")

    times = Float64[]
    allocations = Int[]
    workloads = Set{Tuple{Bool, Float32, Int}}()
    result = warm_result
    for _ in 1:repetitions
        GC.gc()
        measurement = @timed solver()
        result = measurement.value
        push!(times, measurement.time)
        push!(allocations, measurement.bytes)
        push!(workloads, (result.converged, result.eta, result.iterations))
    end
    median_time = median(times)
    println(
        "$name: median=$(round(median_time; digits=4))s " *
        "range=$(round(minimum(times); digits=4))-$(round(maximum(times); digits=4))s " *
        "allocations=$(round(median(allocations) / 2^20; digits=2))MiB " *
        "iterations=$(result.iterations) error=$(result.marginal_error)",
    )
    return (; median_time, result, workloads)
end

println("Problem: $source_count x $target_count, repetitions=$repetitions")
results = Dict{Symbol, Any}()

if CUDA.functional()
    results[:direct_cuda] = benchmark_solver("direct CUDA") do
        solve_sinkhorn_cuda(cost, source_mass, target_mass; solver_options...)
    end
    results[:ka_cuda] = benchmark_solver("KernelAbstractions CUDA") do
        solve_sinkhorn_ka(cost, source_mass, target_mass; backend=:cuda, solver_options...)
    end

    direct = results[:direct_cuda]
    portable = results[:ka_cuda]
    if length(direct.workloads) == 1 && direct.workloads == portable.workloads
        println(
            "End-to-end KA/direct CUDA ratio: " *
            string(round(portable.median_time / direct.median_time; digits=3)),
        )
    else
        println("Not reporting a ratio because convergence histories differ")
    end
else
    println("Skipping CUDA comparisons: CUDA.functional() is false")
end

if oneAPI.functional()
    results[:ka_oneapi] = benchmark_solver("KernelAbstractions oneAPI") do
        solve_sinkhorn_ka(cost, source_mass, target_mass; backend=:oneapi, solver_options...)
    end
else
    println("Skipping oneAPI: oneAPI.functional() is false")
end

if lowercase(get(ENV, "BENCHMARK_CPU", "false")) in ("1", "true", "yes")
    results[:ka_cpu] = benchmark_solver("KernelAbstractions CPU") do
        solve_sinkhorn_ka(cost, source_mass, target_mass; backend=:cpu, solver_options...)
    end
else
    println("Skipping CPU; set BENCHMARK_CPU=true to include it")
end
