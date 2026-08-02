#!/usr/bin/env julia

using AMDGPU
using DataFrames
using PopulationCartogramProjection

const PCP = PopulationCartogramProjection

AMDGPU.functional() || error("AMDGPU is not functional")
AMDGPU.has_rocm_gpu() || error("AMDGPU did not detect a ROCm GPU")

cartogram = DataFrame(x=collect(0:299), y=mod.(0:299, 17))
sources = DataFrame(
    id=1:300,
    x=collect(range(-5, 5; length=300)),
    y=sin.(range(0, 4pi; length=300)),
    value=ones(300),
)
problem = PCP._prepare_problem(cartogram, sources)
backend = AMDGPU.ROCBackend()

function solve(solver)
    snapshot = Ref{Any}()
    solver(
        problem,
        backend;
        eta_schedule=Float32[1e-4],
        observed_etas=Set(Float32[1e-4]),
        observer=result -> (snapshot[] = result; false),
        max_iters_per_eta=3,
        tol=1e-5,
        check_every=3,
    )
    return snapshot[]
end

exact = solve(PCP._solve_exact_sinkhorn)
hybrid = solve(PCP._solve_sinkhorn)
weight_delta = maximum(abs.(
    PCP._source_weights(problem, exact, 150) .-
    PCP._source_weights(problem, hybrid, 150)
))

println("Sampled weight max abs delta: ", weight_delta)
weight_delta <= 2e-5 || error("hybrid weights differ from exact matrix-free")
