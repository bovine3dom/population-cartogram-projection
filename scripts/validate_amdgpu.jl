#!/usr/bin/env julia

using Pkg

const ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(ROOT)
Pkg.instantiate()

using AMDGPU

AMDGPU.versioninfo()
AMDGPU.functional() || error("AMDGPU is not functional; inspect versioninfo() above")
AMDGPU.has_rocm_gpu() || error("AMDGPU did not detect a ROCm GPU")

println("\nRunning the package test suite on $(AMDGPU.device())")
Pkg.test()

println("\nRunning the shared backend benchmark")
ENV["BENCHMARK_CPU"] = get(ENV, "BENCHMARK_CPU", "true")
include(joinpath(ROOT, "benchmark", "compare_solvers.jl"))
