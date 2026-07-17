using CUDA
import KernelAbstractions as KA
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

function benchmark_solver(solver, name; synchronize! = () -> nothing)
    print("Warming $name ... ")
    warm_result = solver()
    synchronize!()
    println("$(warm_result.iterations) iterations")

    measurements = map(1:repetitions) do _
        GC.gc()
        synchronize!()
        @timed begin
            result = solver()
            synchronize!()
            result
        end
    end
    times = [measurement.time for measurement in measurements]
    allocations = [measurement.bytes for measurement in measurements]
    median_time = median(times)
    median_index = argmin(abs.(times .- median_time))
    result = measurements[median_index].value
    println(
        "$name: median=$(round(median_time; digits=4))s " *
        "range=$(round(minimum(times); digits=4))-$(round(maximum(times); digits=4))s " *
        "host_allocations=$(round(median(allocations) / 2^20; digits=2))MiB " *
        "iterations=$(result.iterations) converged=$(result.converged) " *
        "error=$(result.marginal_error)",
    )
end

function print_cuda_context()
    device = CUDA.device()
    dense_cost_mib = 2 * sizeof(Float32) * source_count * target_count / 2^20
    println(
        "CUDA: $(CUDA.name(device)), compute capability $(CUDA.capability(device)); " *
        "Julia $VERSION, CUDA.jl $(Base.pkgversion(CUDA)), " *
        "KernelAbstractions $(Base.pkgversion(KA))",
    )
    println(
        "Dense CUDA cost storage: $(round(dense_cost_mib; digits=3))MiB " *
        "(cost plus transpose, excluding vectors)",
    )
end

println("Problem: $source_count x $target_count, repetitions=$repetitions")

if CUDA.functional()
    print_cuda_context()
    benchmark_solver(
        "KernelAbstractions CUDA";
        synchronize! = CUDA.synchronize,
    ) do
        solve_sinkhorn(cost, source_mass, target_mass; backend=:cuda, solver_options...)
    end
else
    println("Skipping CUDA: CUDA.functional() is false")
end

if oneAPI.functional()
    benchmark_solver("KernelAbstractions oneAPI") do
        solve_sinkhorn(cost, source_mass, target_mass; backend=:oneapi, solver_options...)
    end
else
    println("Skipping oneAPI: oneAPI.functional() is false")
end

if lowercase(get(ENV, "BENCHMARK_CPU", "false")) in ("1", "true", "yes")
    benchmark_solver("KernelAbstractions CPU") do
        solve_sinkhorn(cost, source_mass, target_mass; backend=:cpu, solver_options...)
    end
else
    println("Skipping CPU; set BENCHMARK_CPU=true to include it")
end
