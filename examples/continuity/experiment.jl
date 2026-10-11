module ContinuityExperiment

using Arrow, CSV, DataFrames, H3, LinearAlgebra, Statistics
using PopulationCartogramProjection
import KernelAbstractions as KA
using KernelAbstractions: @kernel, @index, @localmem, @synchronize
const PCP = PopulationCartogramProjection
include(joinpath(@__DIR__, "..", "common.jl"))

# Exact dense reductions: experimental costs must not use the core's spatial pruning.
@kernel function dense_reduce!(out, cost, dual, mass, eta, n, ::Val{ROWS}) where ROWS
    lane = @index(Local, Linear)
    j = @index(Group, Linear)
    maxima = @localmem Float32 (32,)
    totals = @localmem Float32 (32,)
    high = -Inf32
    for i in lane:32:n
        c = ROWS ? cost[j, i] : cost[i, j]
        high = max(high, dual[i] - c)
    end
    maxima[lane] = high
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            maxima[lane] = max(maxima[lane], maxima[lane + offset])
        end
        @synchronize
    end
    j = @index(Group, Linear)
    total = 0.0f0
    for i in lane:32:n
        c = ROWS ? cost[j, i] : cost[i, j]
        total += exp((dual[i] - c - maxima[1]) / eta)
    end
    totals[lane] = total
    @synchronize
    for offset in (16, 8, 4, 2, 1)
        if lane <= offset
            totals[lane] += totals[lane + offset]
        end
        @synchronize
    end
    j = @index(Group, Linear)
    if lane == 1
        out[j] = eta * log(mass[j]) - maxima[1] - eta * log(totals[1])
    end
end

function reconstruct(cost, beta, a, eta)
    logits = (transpose(Float64.(beta)) .- cost) ./ eta
    logits .-= maximum(logits; dims=2)
    plan = exp.(logits)
    plan .*= a ./ vec(sum(plan; dims=2))
    return plan
end

function sinkhorn(cost, a, b, backend; eta=0.002, tolerance=0.00001, maxiters=10000)
    # A target-only offset does not change the optimum. It improves Float32 conditioning.
    shifted = Float32.(cost .- minimum(cost; dims=1))
    dc = PCP._copy_to_backend(backend, shifted)
    da, db = PCP._copy_to_backend(backend, Float32.(a)), PCP._copy_to_backend(backend, Float32.(b))
    alpha, beta = KA.zeros(backend, Float32, length(a)), KA.zeros(backend, Float32, length(b))
    host_beta = zeros(Float32, length(b))
    update! = dense_reduce!(backend, 32)
    error = Inf
    for iteration in 1:maxiters
        update!(alpha, dc, beta, da, Float32(eta), length(b), Val(true); ndrange=32length(a))
        update!(beta, dc, alpha, db, Float32(eta), length(a), Val(false); ndrange=32length(b))
        if iteration % 50 == 0
            PCP._copy_to_host!(backend, host_beta, beta)
            plan = reconstruct(shifted, host_beta, a, eta)
            error = sum(abs.(vec(sum(plan; dims=1)) .- b))
            if error <= tolerance
                return (; plan, iterations=iteration, marginal_error=error)
            end
        end
    end
    Base.error("Sinkhorn did not converge: marginal error=$error")
end

function country(path, code)
    raw = DataFrame(Arrow.Table(path))
    all(==(code), raw.country_code) || error("wrong source country")
    allunique(raw.id) || error("duplicate source ids")
    centres = H3.API.cellToLatLng.(raw.id)
    source = DataFrame(id=UInt64.(raw.id), x=[rad2deg(c.lng) for c in centres],
                       y=[rad2deg(c.lat) for c in centres], value=Float64.(raw.population))
    target = load_cartogram(code)
    PCP._validate_inputs(target, source)
    problem = PCP._prepare_problem(target, source)
    cost = Float64[PCP._cost(problem, i, j) for i in 1:nrow(source), j in 1:nrow(target)]
    xyz = hcat([[cos(c.lat)*cos(c.lng), cos(c.lat)*sin(c.lng), sin(c.lat)] for c in centres]...)
    a = source.value ./ sum(source.value)
    b = fill(1 / nrow(target), nrow(target))
    return (; code, source, target, cost, xyz, a, b)
end

function graph(countries; borders=Set([(276,616)]))
    lookup = Dict((r.x, r.y) => (k, j) for (k, c) in enumerate(countries)
                  for (j, r) in enumerate(eachrow(c.target)))
    edges = Tuple{Int,Int,Int,Int}[]
    for ((x, y), (k, j)) in lookup, pos in ((x+2, y), (x, y+2))
        haskey(lookup, pos) || continue
        l, t = lookup[pos]
        (k == l || minmax(countries[k].code, countries[l].code) in borders) || continue
        push!(edges, (k, j, l, t))
    end
    return sort!(edges)
end

function edge_weights(edges, border_share)
    isnothing(border_share) && return fill(1/max(length(edges),1),length(edges))
    0 <= border_share <= 1 || error("border_share must be between zero and one")
    cross = [e[1]!=e[3] for e in edges]
    n = count(cross)
    0 < n < length(edges) || error("explicit border share requires both edge types")
    return [v ? border_share/n : (1-border_share)/(length(edges)-n) for v in cross]
end

function export_seams(path,countries,plans,edges)
    pairs = sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k != l]))
    isempty(pairs) && return
    CSV.write(path,DataFrame([(; country_a=countries[k].code,country_b=countries[l].code,
        metrics(countries,plans,filter(e -> minmax(e[1],e[3])==(k,l),edges))...)
        for (k,l) in pairs]))
end

means(c, p) = (c.xyz * p) ./ sum(p; dims=1)

function penalty_gradient(countries, plans, edges; scale_km=300.0,
                          weights=fill(1/max(length(edges),1),length(edges)))
    q = [means(c, p) for (c, p) in zip(countries, plans)]
    g = [zeros(size(v)) for v in q]
    tau2 = (scale_km / 6371)^2
    penalty = 0.0
    for ((k, j, l, t), weight) in zip(edges, weights)
        d = q[k][:, j] - q[l][:, t]
        decay = exp(-sum(abs2, d) / (2tau2))
        penalty += weight * (1 - decay)
        derivative = weight .* decay .* d ./ tau2
        g[k][:, j] .+= derivative
        g[l][:, t] .-= derivative
    end
    gradient = [(transpose(c.xyz) * v .- sum(q[k] .* v; dims=1)) ./ sum(plans[k]; dims=1)
                for (k, (c, v)) in enumerate(zip(countries, g))]
    return penalty, gradient
end

function objective(countries, plans, edges, strength, eta; kwargs...)
    base = sum(sum(c.cost .* p) + eta * sum(x -> x > 0 ? x * (log(x)-1) : 0.0, p)
               for (c, p) in zip(countries, plans))
    penalty, _ = penalty_gradient(countries, plans, edges; kwargs...)
    return base + strength * penalty
end

function metrics(countries, plans, edges)
    q = [means(c, p) for (c, p) in zip(countries, plans)]
    unit = [v ./ sqrt.(sum(abs2, v; dims=1)) for v in q]
    distances = [6371acos(clamp(dot(unit[k][:,j], unit[l][:,t]), -1, 1)) for (k,j,l,t) in edges]
    interior = [d for (d,e) in zip(distances, edges) if e[1] == e[3]]
    seam = [d for (d,e) in zip(distances, edges) if e[1] != e[3]]
    spread = vcat([6371sqrt.(max.(0.0, 1 .- vec(sum(abs2,v; dims=1)))) for v in q]...)
    percentile(v, p) = isempty(v) ? 0.0 : quantile(v, p)
    marginal = maximum(sum(abs.(vec(sum(p; dims=1)) .- c.b)) for (c,p) in zip(countries,plans))
    return (; interior_p50=percentile(interior,.5), interior_p90=percentile(interior,.9),
            interior_max=percentile(interior,1), seam_p50=percentile(seam,.5),
            seam_p90=percentile(seam,.9), spread_mean=mean(spread),
            spread_p90=percentile(spread,.9), marginal_error=marginal)
end

function export_mapping(path, countries, plans)
    output = DataFrame(x=Int[], y=Int[], id=UInt64[], code=Int[], weight=Float64[], weight_mean=Float64[])
    for (c, p) in zip(countries, plans)
        totals = vec(sum(p; dims=1))
        for i in axes(p,1)
            weights = p[i,:] ./ c.a[i]
            choice = PCP._select_weights(weights, collect(zip(c.target.x,c.target.y)); indices=true)
            for j in choice.selected
                push!(output, (c.target.x[j], c.target.y[j], c.source.id[i], c.code,
                               weights[j], p[i,j]/totals[j]))
            end
        end
    end
    # Full-plan weight_mean values are not renormalized after sparse extraction.
    Arrow.write(path, output)
end

function run_case(countries, backend, outdir; strength=0.001, eta=0.002, outer_steps=3,
                  borders=Set([(276,616)]), border_share=nothing, scale_km=300.0,
                  interior_limit=Inf)
    ispath(outdir) && error("refusing to overwrite $outdir")
    mkpath(outdir)
    edges = graph(countries; borders)
    weights = edge_weights(edges, border_share)
    score_plan(p) = objective(countries,p,edges,strength,eta; weights,scale_km)
    CSV.write(joinpath(outdir,"settings.csv"), DataFrame(;
        strength=[strength], eta=[eta], scale_km=[scale_km], border_share=[something(border_share,missing)],
        interior_limit=[interior_limit], outer_steps=[outer_steps],
        internal_edges=[count(e -> e[1]==e[3],edges)], border_edges=[count(e -> e[1]!=e[3],edges)]))
    println("Case: $(getproperty.(countries,:code)); sources=$(nrow.(getproperty.(countries,:source))); targets=$(nrow.(getproperty.(countries,:target))); edges=$(length(edges))")
    flush(stdout)
    plans = Matrix{Float64}[]
    for c in countries
        elapsed = @elapsed result = sinkhorn(c.cost, c.a, c.b, backend; eta)
        println("Baseline $(c.code): $(round(elapsed;digits=1)) s, $(result.iterations) iterations, residual=$(result.marginal_error)")
        flush(stdout)
        push!(plans, result.plan)
    end
    baseline = metrics(countries, plans, edges)
    export_mapping(joinpath(outdir,"baseline.arrow"), countries, plans)
    export_seams(joinpath(outdir,"baseline-seams.csv"),countries,plans,edges)
    rows = [(; iteration=0, damping=0.0, accepted=true, objective=score_plan(plans), baseline...)]
    CSV.write(joinpath(outdir,"metrics.csv"), DataFrame(rows))
    trials = NamedTuple[]
    for iteration in 1:outer_steps
        _, gradient = penalty_gradient(countries, plans, edges; weights,scale_km)
        candidate = [sinkhorn(c.cost .+ strength .* g, c.a, c.b, backend; eta).plan
                     for (c,g) in zip(countries,gradient)]
        before = score_plan(plans)
        accepted = false
        for damping in (2.0^-k for k in 1:10)
            trial = [(1-damping).*p .+ damping.*s for (p,s) in zip(plans,candidate)]
            score = score_plan(trial)
            m = metrics(countries,trial,edges)
            acceptable = score < before - 1e-10 && m.spread_mean <= 1.05baseline.spread_mean && m.spread_p90 <= 1.05baseline.spread_p90 &&
                         m.interior_p90 <= interior_limit*baseline.interior_p90 &&
                         m.interior_max <= interior_limit*baseline.interior_max
            push!(trials, (; iteration, damping, accepted=acceptable, objective=score, m...))
            if acceptable
                plans = trial
                push!(rows, (; iteration, damping, accepted=true, objective=score, m...))
                accepted = true
                break
            end
        end
        if !accepted
            push!(rows, (; iteration, damping=0.0, accepted=false, objective=before, metrics(countries,plans,edges)...))
        end
        CSV.write(joinpath(outdir,"metrics.csv"),DataFrame(rows))
        CSV.write(joinpath(outdir,"trials.csv"),DataFrame(trials))
        println("Outer $iteration: $(last(rows))")
        flush(stdout)
        accepted || break
    end
    export_mapping(joinpath(outdir,"candidate.arrow"), countries, plans)
    export_seams(joinpath(outdir,"candidate-seams.csv"),countries,plans,edges)
    return rows
end

end
