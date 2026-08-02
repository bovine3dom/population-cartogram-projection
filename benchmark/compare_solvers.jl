using CSV
using DataFrames
using PopulationCartogramProjection
using Random
using Statistics
using oneAPI

oneAPI.functional() || error(
    "oneAPI is not functional; legacy Intel drivers may require " *
    "ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1",
)

france_mode = !isempty(ARGS) && ARGS[1] == "france"
if france_mode
    length(ARGS) <= 4 || error("usage: compare_solvers.jl france [FACTOR] [REPETITIONS] [ITERATIONS]")
    factor = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1
    repetitions = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 5
    iterations = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 50
    factor > 0 || error("France subdivision factor must be positive")
    include(joinpath(@__DIR__, "..", "examples", "common.jl"))
    raw = CSV.read(
        joinpath(@__DIR__, "..", "examples", "france", "iris-population.csv"),
        DataFrame;
        types=Dict(:index => String),
    )
    included = .!ismissing.(raw.longitude) .& .!ismissing.(raw.latitude) .& [
        value isa Real && !(value isa Bool) && isfinite(value) && value > 0
        for value in raw.population
    ]
    selected = raw[included, :]
    sources = DataFrame(
        id=copy(selected.index),
        x=Float64.(selected.longitude),
        y=Float64.(selected.latitude),
        value=Float64.(selected.population),
    )
    cartogram = select(load_cartogram(250; factor), :x, :y)
    problem_name = "France factor $factor"
else
    source_count = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 256
    target_count = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 256
    repetitions = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 5
    iterations = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 50
    source_count > 0 || error("source count must be positive")
    target_count > 0 || error("target count must be positive")
    Random.seed!(20260801)
    width = ceil(Int, sqrt(target_count))
    cell = 0:(target_count - 1)
    cartogram = DataFrame(x=mod.(cell, width), y=cell .÷ width)
    sources = DataFrame(
        id=1:source_count,
        x=randn(source_count),
        y=randn(source_count),
        value=rand(Float64, source_count) .+ 0.1,
    )
    problem_name = "Synthetic"
end
source_count = nrow(sources)
target_count = nrow(cartogram)
repetitions > 0 || error("repetitions must be positive")
iterations > 0 || error("iteration count must be positive")
backend = oneAPI.oneAPIBackend()
eta = 0.02f0
solver_options = (
    eta_schedule=Float32[eta],
    observed_etas=Set(Float32[eta]),
    max_iters_per_eta=iterations,
    tol=2e-6,
    check_every=iterations,
)

function prepare(cost_mode)
    GC.gc()
    return @timed PopulationCartogramProjection._prepare_problem(
        cartogram, sources; cost_power=2, cost_mode,
    )
end

function solve(problem)
    snapshot = Ref{Any}()
    diagnostics = PopulationCartogramProjection._solve_sinkhorn(
        problem,
        backend;
        solver_options...,
        observer=result -> (snapshot[] = result; false),
    )
    oneAPI.synchronize()
    return (; diagnostics, result=snapshot[])
end

function benchmark_solver(problem, name)
    print("Warming $name ... ")
    warm_result = solve(problem)
    println("$(warm_result.diagnostics.iterations) iterations")
    measurements = map(1:repetitions) do _
        GC.gc()
        oneAPI.synchronize()
        @timed solve(problem)
    end
    times = getproperty.(measurements, :time)
    allocations = getproperty.(measurements, :bytes)
    median_time = median(times)
    median_result = measurements[argmin(abs.(times .- median_time))].value
    diagnostics = median_result.diagnostics
    println(
        "$name: median=$(round(median_time; digits=4))s " *
        "range=$(round(minimum(times); digits=4))-$(round(maximum(times); digits=4))s " *
        "host_allocations=$(round(median(allocations) / 2^20; digits=2))MiB " *
        "iterations=$(diagnostics.iterations) converged=$(diagnostics.converged) " *
        "error=$(diagnostics.marginal_error)",
    )
    return warm_result
end

println(
    "$problem_name: $source_count x $target_count, repetitions=$repetitions, " *
    "iteration_cap=$iterations, Julia threads=$(Threads.nthreads())",
)
println(
    "oneAPI $(Base.pkgversion(oneAPI)), KernelAbstractions " *
    "$(Base.pkgversion(PopulationCartogramProjection.KA)); $(oneAPI.device())",
)

warm_cartogram = first(cartogram, min(target_count, 4))
warm_sources = first(sources, min(source_count, 4))
for cost_mode in (:dense, :matrix_free)
    PopulationCartogramProjection._prepare_problem(
        warm_cartogram, warm_sources; cost_power=2, cost_mode,
    )
end
dense_preparation = prepare(:dense)
matrix_free_preparation = prepare(:matrix_free)
println(
    "Preparation: dense=$(round(dense_preparation.time; digits=4))s/" *
    "$(round(dense_preparation.bytes / 2^20; digits=2))MiB, " *
    "matrix_free=$(round(matrix_free_preparation.time; digits=4))s/" *
    "$(round(matrix_free_preparation.bytes / 2^20; digits=2))MiB",
)

dense_cost_storage = 16 * source_count * target_count
matrix_free_cost_storage = 32 * (source_count + target_count)
println(
    "Theoretical host+device cost storage: dense=" *
    "$(round(dense_cost_storage / 2^20; digits=3))MiB, matrix_free=" *
    "$(round(matrix_free_cost_storage / 2^20; digits=3))MiB " *
    "(high/low coordinates only; excludes shared linear solver vectors)",
)

dense_result = benchmark_solver(dense_preparation.value, "Dense oneAPI")
matrix_free_result = benchmark_solver(
    matrix_free_preparation.value, "Matrix-free tiled oneAPI",
)
beta_offset = dense_result.result.beta[1] - matrix_free_result.result.beta[1]
centered_beta_delta = maximum(abs.(
    dense_result.result.beta .- matrix_free_result.result.beta .- beta_offset,
))
println("Warm-solve centered_beta_max_abs_delta=$centered_beta_delta")
sample_sources = unique((1, cld(source_count, 2), source_count))
source_weight_delta = maximum(sample_sources) do source
    dense_weights = PopulationCartogramProjection._source_weights(
        dense_preparation.value, dense_result.result, source,
    )
    matrix_free_weights = PopulationCartogramProjection._source_weights(
        matrix_free_preparation.value, matrix_free_result.result, source,
    )
    maximum(abs.(dense_weights .- matrix_free_weights))
end
println("Warm-solve sampled_source_weight_max_abs_delta=$source_weight_delta")
