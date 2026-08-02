using CSV
using DataFrames
using PopulationCartogramProjection
using Random
using Statistics
using oneAPI

const PCP = PopulationCartogramProjection

oneAPI.functional() || error(
    "oneAPI is not functional; legacy Intel drivers may require " *
    "ZE_ENABLE_ALT_DRIVERS=/usr/lib/libze_intel_gpu_legacy1.so.1",
)

france_mode = !isempty(ARGS) && ARGS[1] == "france"
if france_mode
    length(ARGS) <= 4 || error(
        "usage: compare_solvers.jl france [FACTOR] [REPETITIONS] [ITERATIONS]",
    )
    factor = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1
    repetitions = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 5
    iterations = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 20
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
    source_count = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1_024
    target_count = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1_024
    repetitions = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 5
    iterations = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 20
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
eta = parse(Float32, get(ENV, "BENCHMARK_ETA", "0.0001"))
backend = oneAPI.oneAPIBackend()
solver_options = (
    eta_schedule=Float32[eta],
    observed_etas=Set(Float32[eta]),
    max_iters_per_eta=iterations,
    tol=2e-6,
    check_every=iterations,
)

PCP._prepare_problem(first(cartogram, min(target_count, 4)), first(sources, min(source_count, 4)))
GC.gc()
preparation = @timed PCP._prepare_problem(cartogram, sources)
problem = preparation.value

function solve(solver)
    snapshot = Ref{Any}()
    diagnostics = solver(
        problem,
        backend;
        solver_options...,
        observer=result -> (snapshot[] = result; false),
    )
    oneAPI.synchronize()
    return (; diagnostics, result=snapshot[])
end

function benchmark_solver(solver, name)
    print("Warming $name ... ")
    warm_result = solve(solver)
    println("$(warm_result.diagnostics.iterations) iterations")
    measurements = map(1:repetitions) do _
        GC.gc()
        oneAPI.synchronize()
        @timed solve(solver)
    end
    times = getproperty.(measurements, :time)
    allocations = getproperty.(measurements, :bytes)
    median_time = median(times)
    result = measurements[argmin(abs.(times .- median_time))].value
    diagnostics = result.diagnostics
    println(
        "$name: median=$(round(median_time; digits=4))s " *
        "range=$(round(minimum(times); digits=4))-$(round(maximum(times); digits=4))s " *
        "host_allocations=$(round(median(allocations) / 2^20; digits=2))MiB " *
        "converged=$(diagnostics.converged) error=$(diagnostics.marginal_error)",
    )
    return result
end

leaf_blocks = cld(source_count, 32) + cld(target_count, 32)
coarse_blocks = cld(source_count, 256) + cld(target_count, 256)
matrix_free_storage = 32 * (source_count + target_count)
hybrid_storage = 40 * (source_count + target_count) + 36 * (leaf_blocks + coarse_blocks)

println(
    "$problem_name: $source_count x $target_count, repetitions=$repetitions, " *
    "iteration_cap=$iterations, eta=$eta, Julia threads=$(Threads.nthreads())",
)
println(
    "oneAPI $(Base.pkgversion(oneAPI)), KernelAbstractions $(Base.pkgversion(PCP.KA)); " *
    "$(oneAPI.device())",
)
println(
    "Preparation: $(round(preparation.time; digits=4))s/" *
    "$(round(preparation.bytes / 2^20; digits=2))MiB",
)
println(
    "Theoretical host+device geometry storage: exact=" *
    "$(round(matrix_free_storage / 2^20; digits=3))MiB, hybrid=" *
    "$(round(hybrid_storage / 2^20; digits=3))MiB",
)

exact = benchmark_solver(PCP._solve_exact_sinkhorn, "Exact matrix-free")
hybrid = benchmark_solver(PCP._solve_sinkhorn, "Default hybrid")
beta_offset = hybrid.result.beta[1] - exact.result.beta[1]
println("Centered beta max abs delta=", maximum(abs.(
    hybrid.result.beta .- exact.result.beta .- beta_offset,
)))
sample_sources = unique((1, cld(source_count, 2), source_count))
weight_delta = maximum(sample_sources) do source
    exact_weights = PCP._source_weights(problem, exact.result, source)
    hybrid_weights = PCP._source_weights(problem, hybrid.result, source)
    maximum(abs.(exact_weights .- hybrid_weights))
end
println("Sampled weight max abs delta=$weight_delta")
