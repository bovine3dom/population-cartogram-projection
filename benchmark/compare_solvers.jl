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

france_mode = !isempty(ARGS) && ARGS[1] in ("france", "france-mf")
matrix_free_only = !isempty(ARGS) && ARGS[1] == "france-mf"
compare_truncated = get(ENV, "BENCHMARK_TRUNCATED", "false") == "true"
truncation_tolerance = parse(Float64, get(ENV, "BENCHMARK_TRUNCATION_TOLERANCE", "1e-6"))
truncation_eta = parse(Float64, get(ENV, "BENCHMARK_TRUNCATION_ETA", "0.001"))
if france_mode
    length(ARGS) <= 4 || error(
        "usage: compare_solvers.jl france[-mf] [FACTOR] [REPETITIONS] [ITERATIONS]",
    )
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
    problem_name = "France factor $factor" * (matrix_free_only ? " matrix-free only" : "")
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
eta = parse(Float32, get(ENV, "BENCHMARK_ETA", "0.02"))
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
        cartogram,
        sources;
        cost_power=2,
        cost_mode,
        truncation_tolerance,
        truncation_eta,
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
    if hasproperty(diagnostics, :truncation)
        truncation = diagnostics.truncation
        exact_reference_pairs = truncation.possible_pairs +
                                truncation.exact_pair_evaluations
        println(
            "  active_blocks=$(truncation.active_blocks)/$(truncation.possible_blocks) " *
            "truncated_main_pairs=$(truncation.evaluated_pairs)/" *
            "$(truncation.possible_pairs) exact_pairs=" *
            "$(truncation.exact_pair_evaluations) witness_pair_upper_bound=" *
            "$(truncation.witness_pair_upper_bound) total_pair_upper_bound=" *
            "$(truncation.pair_evaluation_upper_bound)/$exact_reference_pairs",
        )
    end
    return warm_result
end

println(
    "$problem_name: $source_count x $target_count, repetitions=$repetitions, " *
    "iteration_cap=$iterations, eta=$eta, Julia threads=$(Threads.nthreads())",
)
println(
    "oneAPI $(Base.pkgversion(oneAPI)), KernelAbstractions " *
    "$(Base.pkgversion(PopulationCartogramProjection.KA)); $(oneAPI.device())",
)
compare_truncated && println(
    "Truncation: tolerance=$truncation_tolerance, maximum_eta=$truncation_eta",
)

warm_cartogram = first(cartogram, min(target_count, 4))
warm_sources = first(sources, min(source_count, 4))
warm_modes = matrix_free_only ? Symbol[:matrix_free] : Symbol[:dense, :matrix_free]
compare_truncated && push!(warm_modes, :truncated)
for cost_mode in warm_modes
    PopulationCartogramProjection._prepare_problem(
        warm_cartogram, warm_sources; cost_power=2, cost_mode,
    )
end
dense_preparation = matrix_free_only ? nothing : prepare(:dense)
matrix_free_preparation = prepare(:matrix_free)
truncated_preparation = compare_truncated ? prepare(:truncated) : nothing
matrix_free_cost_storage = 32 * (source_count + target_count)
leaf_blocks = cld(source_count, 32) + cld(target_count, 32)
coarse_blocks = cld(source_count, 256) + cld(target_count, 256)
truncated_cost_storage = 56 * (source_count + target_count) +
                         36 * (leaf_blocks + coarse_blocks)
preparation_reports = String[]
if !isnothing(dense_preparation)
    push!(preparation_reports,
        "dense=$(round(dense_preparation.time; digits=4))s/" *
        "$(round(dense_preparation.bytes / 2^20; digits=2))MiB",
    )
end
push!(preparation_reports,
    "matrix_free=$(round(matrix_free_preparation.time; digits=4))s/" *
    "$(round(matrix_free_preparation.bytes / 2^20; digits=2))MiB",
)
if compare_truncated
    push!(preparation_reports,
        "truncated=$(round(truncated_preparation.time; digits=4))s/" *
        "$(round(truncated_preparation.bytes / 2^20; digits=2))MiB",
    )
end
println("Preparation: ", join(preparation_reports, ", "))

storage_reports = String[]
!isnothing(dense_preparation) && push!(storage_reports,
    "dense=$(round(16 * source_count * target_count / 2^20; digits=3))MiB",
)
push!(storage_reports,
    "matrix_free=$(round(matrix_free_cost_storage / 2^20; digits=3))MiB",
)
compare_truncated && push!(storage_reports,
    "truncated=$(round(truncated_cost_storage / 2^20; digits=3))MiB",
)
println(
    "Theoretical host+device cost storage: ", join(storage_reports, ", "),
    " (matrix-free uses high/low coordinates; truncated adds hierarchy and " *
    "counters; all exclude shared solver vectors)",
)

sample_sources = unique((1, cld(source_count, 2), source_count))
if !isnothing(dense_preparation)
    dense_result = benchmark_solver(dense_preparation.value, "Dense oneAPI")
end
matrix_free_result = benchmark_solver(
    matrix_free_preparation.value, "Matrix-free tiled oneAPI",
)
if !isnothing(dense_preparation)
    beta_offset = dense_result.result.beta[1] - matrix_free_result.result.beta[1]
    centered_beta_delta = maximum(abs.(
        dense_result.result.beta .- matrix_free_result.result.beta .- beta_offset,
    ))
    println("Warm-solve centered_beta_max_abs_delta=$centered_beta_delta")
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
end
if compare_truncated
    truncated_result = benchmark_solver(
        truncated_preparation.value, "Dual-aware truncated oneAPI",
    )
    truncated_weight_delta = maximum(sample_sources) do source
        exact_weights = PopulationCartogramProjection._source_weights(
            matrix_free_preparation.value, matrix_free_result.result, source,
        )
        truncated_weights = PopulationCartogramProjection._source_weights(
            truncated_preparation.value, truncated_result.result, source,
        )
        maximum(abs.(exact_weights .- truncated_weights))
    end
    println(
        "Warm-solve truncated_sampled_weight_max_abs_delta=$truncated_weight_delta",
    )
end
