using DataFrames
import KernelAbstractions as KA
using PopulationCartogramProjection
using Test

const PCP = PopulationCartogramProjection

function fixture()
    cartogram = DataFrame(x=[0, 1, 2], y=[0, 0, 0])
    sources = DataFrame(
        id=UInt64[0x8a2a10728907fff, 0x8a2a1072890ffff],
        x=[-1.0, 1.0],
        y=[51.0, 50.0],
        value=[40.0, 60.0],
    )
    return (; cartogram, sources)
end

function solve(problem, backend=KA.CPU(); eta=0.1f0, iterations=5_000, tol=1e-6)
    snapshot = Ref{Any}()
    diagnostics = PCP._solve_sinkhorn(
        problem,
        backend;
        eta_schedule=Float32[eta],
        observed_etas=Set(Float32[eta]),
        observer=result -> (snapshot[] = result; false),
        max_iters_per_eta=iterations,
        tol,
        check_every=10,
    )
    return snapshot[], diagnostics
end

function check_mapping(mapping, cartogram, sources)
    @test propertynames(mapping) == [:x, :y, :id, :weight, :weight_mean]
    @test eltype(mapping.id) == eltype(sources.id)
    @test all(isfinite, mapping.weight)
    @test all(isfinite, mapping.weight_mean)
    @test all(weight -> 0 < weight <= 1, mapping.weight)
    @test all(weight -> 0 < weight <= 1, mapping.weight_mean)
    @test Set(zip(mapping.x, mapping.y)) <= Set(zip(cartogram.x, cartogram.y))
    @test Set(mapping.id) == Set(sources.id)

    source_totals = combine(groupby(mapping, :id), :weight => sum => :weight)
    @test all(
        weight -> PCP.CUMULATIVE_WEIGHT <= weight <= 1 + 10eps(Float64),
        source_totals.weight,
    )
    target_totals = combine(groupby(mapping, [:x, :y]), :weight_mean => sum => :weight)
    @test all(weight -> isapprox(weight, 1; atol=1e-12), target_totals.weight)

    contributions = leftjoin(mapping, select(sources, :id, :value); on=:id)
    contributions.transport = contributions.weight .* contributions.value
    transform!(
        groupby(contributions, [:x, :y]),
        :transport => (values -> values ./ sum(values)) => :expected_weight_mean,
    )
    @test mapping.weight_mean ≈ contributions.expected_weight_mean atol=1e-12
end

function dense_oracle(problem, eta; max_iterations=10_000, tolerance=1e-10)
    sources = length(problem.source_mass)
    targets = length(problem.target_mass)
    cost = Float64[
        PCP._cost(problem, source, target)
        for source in 1:sources, target in 1:targets
    ]
    source_mass = Float64.(problem.source_mass)
    target_mass = Float64.(problem.target_mass)
    alpha = zeros(sources)
    beta = zeros(targets)
    function logsumexp(values)
        maximum_value = maximum(values)
        return maximum_value + log(sum(exp(value - maximum_value) for value in values))
    end

    for iteration in 1:max_iterations
        for source in 1:sources
            alpha[source] = eta * log(source_mass[source]) - eta * logsumexp(
                (beta[target] - cost[source, target]) / eta for target in 1:targets
            )
        end
        for target in 1:targets
            beta[target] = eta * log(target_mass[target]) - eta * logsumexp(
                (alpha[source] - cost[source, target]) / eta for source in 1:sources
            )
        end
        if iteration % 10 == 0
            transport = exp.((alpha .+ transpose(beta) .- cost) ./ eta)
            error = sum(abs.(vec(sum(transport; dims=2)) .- source_mass)) +
                    sum(abs.(vec(sum(transport; dims=1)) .- target_mass))
            error <= tolerance && break
        end
    end
    weights = exp.((transpose(beta) .- cost) ./ eta)
    weights ./= sum(weights; dims=2)
    return weights
end

function reference_cost(cartogram, sources)
    target_x = PCP._normalized_axis(cartogram.x)
    target_y = PCP._normalized_axis(cartogram.y)
    source_x = PCP._scale_to_cartogram(Float64.(sources.x), target_x)
    source_y = PCP._scale_to_cartogram(-Float64.(sources.y), target_y)
    step_x = PCP._minimum_step(target_x)
    step_y = PCP._minimum_step(target_y)
    bound = hypot(
        (maximum(target_x) - minimum(target_x)) / step_x,
        (maximum(target_y) - minimum(target_y)) / step_y,
    )
    distances = Float64[
        bound == 0 ? 0 : hypot(
            (source_x[source] - target_x[target]) / step_x / bound,
            (source_y[source] - target_y[target]) / step_y / bound,
        )
        for source in 1:nrow(sources), target in 1:nrow(cartogram)
    ]
    scale = maximum(distances)
    return scale == 0 ? distances : (distances ./ scale) .^ 2
end

@testset "input contract" begin
    (; cartogram, sources) = fixture()
    backend = KA.CPU()
    @test_throws UndefKeywordError distribute(cartogram, sources)
    @test_throws ArgumentError distribute(select(cartogram, :x), sources; backend)
    @test_throws ArgumentError distribute(cartogram, select(sources, Not(:id)); backend)
    @test_throws ArgumentError distribute(cartogram[1:0, :], sources; backend)
    @test_throws ArgumentError distribute(cartogram, sources[1:0, :]; backend)
    @test_throws ArgumentError distribute(vcat(cartogram, cartogram[1:1, :]), sources; backend)
    @test_throws ArgumentError distribute(
        DataFrame(x=BigInt[big(2)^54, big(2)^54 + 1], y=[0, 0]), sources; backend,
    )
    @test_throws ArgumentError distribute(
        DataFrame(x=[-0.0, 0.0], y=[0.0, 0.0]), sources; backend,
    )
    @test_throws ArgumentError distribute(cartogram, vcat(sources, sources[1:1, :]); backend)

    missing_id = copy(sources)
    allowmissing!(missing_id, :id)
    missing_id.id[1] = missing
    @test_throws ArgumentError distribute(cartogram, missing_id; backend)
    for value in (0.0, -1.0, Inf, NaN, true, big"1e400")
        invalid = copy(sources)
        invalid.value = Any[value, 1.0]
        @test_throws ArgumentError distribute(cartogram, invalid; backend)
    end
    invalid_coordinate = copy(sources)
    invalid_coordinate.x[1] = Inf
    @test_throws ArgumentError distribute(cartogram, invalid_coordinate; backend)
    @test_throws ArgumentError distribute(
        DataFrame(x=[0.0, nextfloat(0.0), 1.0], y=zeros(3)), sources; backend,
    )
    extreme_range = copy(sources)
    extreme_range.value = [nextfloat(0.0), 1.0]
    @test_throws ArgumentError distribute(cartogram, extreme_range; backend)
    normalized_underflow = DataFrame(
        id=1:3,
        x=[0.0, 1.0, 2.0],
        y=[0.0, 1.0, 2.0],
        value=[Float64(nextfloat(0.0f0)), 1.0, 1.0],
    )
    @test_throws ArgumentError distribute(cartogram, normalized_underflow; backend)
    @test_throws MethodError distribute(cartogram, sources; backend, cost_mode=:dense)

    extreme_coordinates = copy(sources)
    extreme_coordinates.x = [-floatmax(Float64), floatmax(Float64)]
    @test all(isfinite, distribute(cartogram, extreme_coordinates; backend).weight)

    _, target_mass = PCP._masses(DataFrame(x=1:100_000), sources)
    @test all(==(first(target_mass)), target_mass)
    @test first(target_mass) > 0
    @test sum(Float64, target_mass) ≈ 1 atol=1e-6
end

@testset "public distribution" begin
    (; cartogram, sources) = fixture()
    mapping = distribute(cartogram, sources; backend=KA.CPU())
    check_mapping(mapping, cartogram, sources)

    extra_sources = transform(sources, :id => ByRow(string) => :label)
    extra_cartogram = transform(cartogram, :x => ByRow(string) => :label)
    @test distribute(extra_cartogram, extra_sources; backend=KA.CPU()) == mapping

    permuted = distribute(cartogram, sources[[2, 1], :]; backend=KA.CPU())
    @test sort(mapping, [:id, :x, :y]) ≈ sort(permuted, [:id, :x, :y])
    permuted_cartogram = distribute(cartogram[[3, 1, 2], :], sources; backend=KA.CPU())
    @test sort(mapping, [:id, :x, :y]) ≈ sort(permuted_cartogram, [:id, :x, :y])

    large_values = copy(sources)
    large_values.value .= [floatmax(Float64), floatmax(Float64) / 2]
    @test all(isfinite, distribute(cartogram, large_values; backend=KA.CPU()).weight_mean)
end

@testset "matrix-free solver" begin
    tiled_cartogram = DataFrame(x=collect(0:36), y=mod.(0:36, 7))
    tiled_sources = DataFrame(
        id=collect(1:9),
        x=collect(range(-2, 2; length=9)),
        y=collect(range(55, 47; length=9)),
        value=Float64.(1:9),
    )
    problem = PCP._prepare_problem(tiled_cartogram, tiled_sources)
    @test problem isa PCP.MatrixFreeProblem
    @test !hasproperty(problem, :cost)
    expected_cost = reference_cost(tiled_cartogram, tiled_sources)
    @test maximum(
        abs(Float64(PCP._cost(problem, source, target)) - expected_cost[source, target])
        for source in 1:nrow(tiled_sources), target in 1:nrow(tiled_cartogram)
    ) <= 2e-6

    (; cartogram, sources) = fixture()
    small_problem = PCP._prepare_problem(cartogram, sources)
    result, diagnostics = solve(small_problem)
    @test diagnostics.converged
    exact_weights = dense_oracle(small_problem, Float64(result.eta))
    actual_weights = reduce(vcat, [
        transpose(PCP._source_weights(small_problem, result, source))
        for source in 1:nrow(sources)
    ])
    @test actual_weights ≈ exact_weights atol=2e-5
    transported = Float64.(small_problem.source_mass) .* actual_weights
    @test vec(sum(transported; dims=1)) ≈ small_problem.target_mass atol=2e-5

    terms = 100_000
    logit = Float32(log(1e-8))
    reduction_dual = fill(logit, terms + 1)
    reduction_dual[1] = 0
    accumulator_problem = PCP.MatrixFreeProblem(
        Float32[0], Float32[0], Float32[0], Float32[0],
        zeros(Float32, terms + 1), zeros(Float32, terms + 1),
        zeros(Float32, terms + 1), zeros(Float32, terms + 1),
        0.0f0, Float32[1], fill(inv(Float32(terms + 1)), terms + 1),
    )
    logsum = PCP._matrix_free_cpu_value(
        accumulator_problem,
        Float32[0],
        reduction_dual,
        Float32[1],
        1.0f0,
        1,
        terms + 1,
        Val(true),
        Val(false),
    )
    @test logsum ≈ log1p(terms * exp(Float64(logit))) atol=1e-7
end

@testset "automatic sparsity" begin
    selection = PCP._select_weights(
        [0.994, 0.003, 0.003], [(0, 0), (2, 0), (1, 0)]; indices=true,
    )
    @test selection.selected == [1, 3]
    @test selection.count == 2

    cartogram = DataFrame(x=[0, 0], y=[0, 2])
    sources = DataFrame(
        id=["north", "south"], x=[0.0, 0.0], y=[60.0, 50.0], value=[1.0, 1.0],
    )
    mapping = distribute(cartogram, sources; backend=KA.CPU())
    check_mapping(mapping, cartogram, sources)
    @test nrow(mapping) <= nrow(cartogram) * nrow(sources)
end

@testset "truncation bounds" begin
    cartogram = DataFrame(x=collect(0:36), y=mod.(0:36, 7))
    sources = DataFrame(
        id=collect(1:9),
        x=collect(range(-2, 2; length=9)),
        y=collect(range(55, 47; length=9)),
        value=Float64.(1:9),
    )
    problem = PCP._prepare_problem(cartogram, sources)
    workspace = PCP._prepare_truncation(problem)
    @test sort(Int.(workspace.source_blocks.indices)) == collect(1:nrow(sources))
    @test sort(Int.(workspace.target_blocks.indices)) == collect(1:nrow(cartogram))

    dual = Float32[sin(index) for index in 1:nrow(cartogram)]
    for bounds in (workspace.target_blocks.leaf, workspace.target_blocks.coarse)
        block_size = bounds === workspace.target_blocks.leaf ?
                     PCP.TRUNCATION_BLOCK_SIZE : PCP.TRUNCATION_COARSE_SIZE
        for source in 1:nrow(sources), block in eachindex(bounds.minimum_x)
            positions = ((block - 1) * block_size + 1):min(
                block * block_size, length(workspace.target_blocks.indices),
            )
            targets = Int.(workspace.target_blocks.indices[positions])
            lower_cost = PCP._block_lower_cost(
                problem.source_x_hi[source],
                problem.source_x_lo[source],
                problem.source_y_hi[source],
                problem.source_y_lo[source],
                bounds.minimum_x[block],
                bounds.maximum_x[block],
                bounds.minimum_y[block],
                bounds.maximum_y[block],
                problem.inverse_distance_scale,
            )
            @test maximum(dual[targets]) - lower_cost >= maximum(
                dual[target] - PCP._cost(problem, source, target) for target in targets
            )
        end
    end

    wide_cartogram = DataFrame(x=mod.(0:299, 20), y=(0:299) .÷ 20)
    wide_sources = DataFrame(
        id=1:300,
        x=collect(range(-5, 5; length=300)),
        y=sin.(range(0, 4pi; length=300)),
        value=ones(300),
    )
    wide_problem = PCP._prepare_problem(wide_cartogram, wide_sources)
    wide_workspace = PCP._prepare_truncation(wide_problem)
    @test length(wide_workspace.source_blocks.coarse.minimum_x) > 1
    @test length(wide_workspace.target_blocks.coarse.minimum_x) > 1

    function omitted_mass(output, source_output, dual, eta)
        blocks = source_output ? wide_workspace.target_blocks : wide_workspace.source_blocks
        reductions = source_output ? length(wide_problem.target_mass) :
                     length(wide_problem.source_mass)
        positions(block, size, count) = ((block - 1) * size + 1):min(block * size, count)
        output_x_hi = source_output ? wide_problem.source_x_hi[output] :
                      wide_problem.target_x_hi[output]
        output_x_lo = source_output ? wide_problem.source_x_lo[output] :
                      wide_problem.target_x_lo[output]
        output_y_hi = source_output ? wide_problem.source_y_hi[output] :
                      wide_problem.target_y_hi[output]
        output_y_lo = source_output ? wide_problem.source_y_lo[output] :
                      wide_problem.target_y_lo[output]
        upper(bounds, maxima, block) = maxima[block] - PCP._block_lower_cost(
            output_x_hi, output_x_lo, output_y_hi, output_y_lo,
            bounds.minimum_x[block], bounds.maximum_x[block],
            bounds.minimum_y[block], bounds.maximum_y[block],
            wide_problem.inverse_distance_scale,
        )
        leaf_maxima = Float32[
            maximum(
                dual[Int(blocks.indices[position])]
                for position in positions(block, PCP.TRUNCATION_BLOCK_SIZE, reductions)
            )
            for block in eachindex(blocks.leaf.minimum_x)
        ]
        coarse_maxima = Float32[
            maximum(@view leaf_maxima[positions(
                coarse, PCP.TRUNCATION_COARSE_BLOCKS, length(leaf_maxima),
            )])
            for coarse in eachindex(blocks.coarse.minimum_x)
        ]
        anchor_coarse = argmax([
            upper(blocks.coarse, coarse_maxima, block) for block in eachindex(coarse_maxima)
        ])
        anchor_leaves = positions(
            anchor_coarse, PCP.TRUNCATION_COARSE_BLOCKS, length(leaf_maxima),
        )
        anchor_leaf = first(anchor_leaves) - 1 + argmax([
            upper(blocks.leaf, leaf_maxima, block) for block in anchor_leaves
        ])
        score(reduction) = Float64(dual[reduction]) - Float64(
            source_output ? PCP._cost(wide_problem, output, reduction) :
            PCP._cost(wide_problem, reduction, output),
        )
        lower_score = maximum(
            score(Int(blocks.indices[position]))
            for position in positions(anchor_leaf, PCP.TRUNCATION_BLOCK_SIZE, reductions)
        ) - PCP.TRUNCATION_BOUND_GUARD
        margin = eta * PCP._truncation_log_budget(
            reductions, PCP.TRUNCATION_TOLERANCE,
        ) + PCP.TRUNCATION_BOUND_GUARD
        active = falses(reductions)
        for coarse in eachindex(coarse_maxima)
            coarse == anchor_coarse ||
                upper(blocks.coarse, coarse_maxima, coarse) + margin >= lower_score || continue
            for leaf in positions(coarse, PCP.TRUNCATION_COARSE_BLOCKS, length(leaf_maxima))
                leaf == anchor_leaf ||
                    upper(blocks.leaf, leaf_maxima, leaf) + margin >= lower_score || continue
                active[positions(leaf, PCP.TRUNCATION_BLOCK_SIZE, reductions)] .= true
            end
        end
        scores = Float64[score(Int(index)) for index in blocks.indices]
        weights = exp.((scores .- maximum(scores)) ./ Float64(eta))
        return sum(weights[.!active]) / sum(weights), count(active)
    end

    for output in (1, 150, 300), source_output in (false, true)
        omitted, active = omitted_mass(output, source_output, zeros(Float32, 300), 1.0f-4)
        @test omitted <= PCP.TRUNCATION_TOLERANCE
        @test 0 < active < 300
    end
end

@testset "dependency boundary" begin
    for vendor in (:CUDA, :AMDGPU, :oneAPI, :Metal)
        @test !isdefined(PCP, vendor)
    end
end
