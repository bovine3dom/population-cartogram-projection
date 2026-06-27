using CUDA, SparseArrays, LinearAlgebra
using JuMP, HiGHS
# gemini 3.5 flash vomit draft implementation of https://arxiv.org/abs/2605.08793

# ==============================================================================
# 1. FUSED CUDA KERNELS FOR GRADIENT EVALUATION & SINKHORN ITERATIONS
# ==============================================================================

"""
Fused CUDA kernel with hardcoded compile-time dimensions for shared memory 
to prevent type-inference and memory-corruption issues in CUDA.jl.
"""
function fused_grad_kernel!(M, alpha, beta, eta, row_sums, col_sums, n, m)
    tx = threadIdx().x
    ty = threadIdx().y
    bx = blockIdx().x
    by = blockIdx().y
    
    FT = eltype(M)
    
    # Declare dynamic shared memory stably using a flat 1D compile-time size (32 * 8 = 256)
    shared_cols = CUDA.CuDynamicSharedArray(FT, 256)
    
    i = (by - 1) * blockDim().y + ty
    j = (bx - 1) * blockDim().x + tx
    
    T_ij = zero(FT)
    if i <= n && j <= m
        T_ij = exp((alpha[i] + beta[j] - M[i, j]) / eta)
    end
    
    # --- Warp-level Row Reduction ---
    val = T_ij
    mask = 0xffffffff
    for offset in (16, 8, 4, 2, 1)
        val += CUDA.shfl_down_sync(mask, val, offset)
    end
    
    if tx == 1 && i <= n
        CUDA.@atomic row_sums[i] += val
    end
    
    # --- 1D Column-Major Shared Memory Assignment ---
    shared_cols[tx + (ty - 1) * 32] = T_ij
    CUDA.sync_threads()
    
    # --- Shared Memory Column Reduction ---
    if ty == 1 && j <= m
        sum_col_block = zero(FT)
        # Use a compile-time constant (8) instead of blockDim().y
        for k in 1:8
            sum_col_block += shared_cols[tx + (k - 1) * 32]
        end
        CUDA.@atomic col_sums[j] += sum_col_block
    end
    
    return
end

"""
CUDA kernel for a single row-update step of the log-stabilized Sinkhorn algorithm.
"""
function sinkhorn_row_kernel!(M, alpha, beta, eta, a, n, m)
    i = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    if i <= n
        max_val = -Inf32
        for j in 1:m
            val = beta[j] - M[i, j]
            if val > max_val
                max_val = val
            end
        end
        
        sum_exp = 0.0f0
        for j in 1:m
            sum_exp += exp((beta[j] - M[i, j] - max_val) / eta)
        end
        
        alpha[i] = eta * log(a[i]) - max_val - eta * log(sum_exp)
    end
    return
end

"""
CUDA kernel for a single column-update step of the log-stabilized Sinkhorn algorithm.
"""
function sinkhorn_col_kernel!(M, alpha, beta, eta, b, n, m)
    j = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    if j <= m
        max_val = -Inf32
        for i in 1:n
            val = alpha[i] - M[i, j]
            if val > max_val
                max_val = val
            end
        end
        
        sum_exp = 0.0f0
        for i in 1:n
            sum_exp += exp((alpha[i] - M[i, j] - max_val) / eta)
        end
        
        beta[j] = eta * log(b[j]) - max_val - eta * log(sum_exp)
    end
    return
end

function sinkhorn_row_block_kernel!(Mt, alpha, beta, eta, a, n, m)
    i = blockIdx().x
    tid = threadIdx().x
    block_size = blockDim().x
    FT = eltype(Mt)
    shared = CUDA.CuDynamicSharedArray(FT, block_size)

    max_val = FT(-Inf)
    j = tid
    while j <= m
        val = beta[j] - Mt[j, i]
        if val > max_val
            max_val = val
        end
        j += block_size
    end

    shared[tid] = max_val
    CUDA.sync_threads()

    offset = block_size >>> 1
    while offset >= 1
        if tid <= offset
            other = shared[tid + offset]
            if other > shared[tid]
                shared[tid] = other
            end
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    row_max = shared[1]
    sum_exp = zero(FT)
    j = tid
    while j <= m
        sum_exp += exp((beta[j] - Mt[j, i] - row_max) / eta)
        j += block_size
    end

    shared[tid] = sum_exp
    CUDA.sync_threads()

    offset = block_size >>> 1
    while offset >= 1
        if tid <= offset
            shared[tid] += shared[tid + offset]
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    if tid == 1
        alpha[i] = eta * log(a[i]) - row_max - eta * log(shared[1])
    end

    return
end

function sinkhorn_col_block_kernel!(M, alpha, beta, eta, b, n, m)
    j = blockIdx().x
    tid = threadIdx().x
    block_size = blockDim().x
    FT = eltype(M)
    shared = CUDA.CuDynamicSharedArray(FT, block_size)

    max_val = FT(-Inf)
    i = tid
    while i <= n
        val = alpha[i] - M[i, j]
        if val > max_val
            max_val = val
        end
        i += block_size
    end

    shared[tid] = max_val
    CUDA.sync_threads()

    offset = block_size >>> 1
    while offset >= 1
        if tid <= offset
            other = shared[tid + offset]
            if other > shared[tid]
                shared[tid] = other
            end
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    col_max = shared[1]
    sum_exp = zero(FT)
    i = tid
    while i <= n
        sum_exp += exp((alpha[i] - M[i, j] - col_max) / eta)
        i += block_size
    end

    shared[tid] = sum_exp
    CUDA.sync_threads()

    offset = block_size >>> 1
    while offset >= 1
        if tid <= offset
            shared[tid] += shared[tid + offset]
        end
        CUDA.sync_threads()
        offset >>>= 1
    end

    if tid == 1
        beta[j] = eta * log(b[j]) - col_max - eta * log(shared[1])
    end

    return
end

# ==============================================================================
# 2. AUXILIARY CPU / GPU UTILITY FUNCTIONS
# ==============================================================================

"""
Evaluates the dual objective value f(x) and computes the gradient.
"""
function evaluate_gradient_and_obj!(M, alpha, beta, eta, row_sums, col_sums, a, b, n, m, g_gpu)
    CUDA.fill!(row_sums, 0.0)
    CUDA.fill!(col_sums, 0.0)
    
    D = 8
    threads = (32, D)
    blocks = (div(m + 31, 32), div(n + D - 1, D))
    shmem = 32 * D * sizeof(eltype(M))
    
    @cuda threads=threads blocks=blocks shmem=shmem fused_grad_kernel!(M, alpha, beta, eta, row_sums, col_sums, n, m)
    
    # Map back to dual variable objective and gradient format
    g_gpu[1:n] .= row_sums .- a
    g_gpu[n+1:n+m-1] .= col_sums[1:m-1] .- b[1:m-1]
    
    obj = eta * sum(row_sums) - dot(alpha, a) - dot(beta, b)
    return obj
end

"""
Runs log-stabilized Sinkhorn iterations on the GPU.
"""
function run_sinkhorn_gpu!(alpha, beta, M, a, b, eta, n, m, num_iters)
    threads = 256
    blocks_row = div(n + threads - 1, threads)
    blocks_col = div(m + threads - 1, threads)
    
    for _ in 1:num_iters
        @cuda threads=threads blocks=blocks_row sinkhorn_row_kernel!(M, alpha, beta, eta, a, n, m)
        @cuda threads=threads blocks=blocks_col sinkhorn_col_kernel!(M, alpha, beta, eta, b, n, m)
    end
    CUDA.@allowscalar beta[m] = 0.0  # Maintain the beta_m = 0 constraint
end

"""
Assembles the sparse Hessian matrix H_omega on the CPU.
If indices are supplied, computes only the values at the active sparsified positions.
"""
function build_H_omega_cpu(alpha_cpu, beta_cpu, M_cpu, eta, row_sums_cpu, col_sums_cpu, k, n, m; indices=nothing)
    if isnothing(indices)
        # 1. Compute T for the submatrix (n x m-1) and select top-k entries
        T_sub = exp.((alpha_cpu .+ beta_cpu[1:m-1]' .- M_cpu[:, 1:m-1]) ./ eta)
        
        if k < n * (m - 1)
            threshold = partialsort(vec(T_sub), k, rev=true)
        else
            threshold = 0.0
        end
        
        I_idx, J_idx, V_val = Int[], Int[], Float64[]
        for j in 1:(m-1), i in 1:n
            val = T_sub[i, j]
            if val >= threshold
                push!(I_idx, i)
                push!(J_idx, j)
                push!(V_val, val)
            end
        end
        T_sub_omega = sparse(I_idx, J_idx, V_val, n, m-1)
        active_indices = (I_idx, J_idx)
    else
        I_idx, J_idx = indices
        V_val = [exp((alpha_cpu[i] + beta_cpu[j] - M_cpu[i, j]) / eta) for (i, j) in zip(I_idx, J_idx)]
        T_sub_omega = sparse(I_idx, J_idx, V_val, n, m-1)
        active_indices = indices
    end
    
    D1 = sparse(1:n, 1:n, row_sums_cpu, n, n)
    D2 = sparse(1:(m-1), 1:(m-1), col_sums_cpu[1:m-1], m-1, m-1)
    
    H_omega = [D1 T_sub_omega; T_sub_omega' D2]
    H_omega .*= (1.0 / eta)
    
    return H_omega, active_indices
end

# ==============================================================================
# 3. BACKTRACKING LINE SEARCH
# ==============================================================================

function backtracking_line_search(M_gpu, alpha_gpu, beta_gpu, d_gpu, g_gpu, obj_old, a_gpu, b_gpu, eta, n, m, row_sums_gpu, col_sums_gpu, g_scratch)
    gamma = 1.0
    c1 = 1e-4
    
    d_alpha = d_gpu[1:n]
    d_beta = CUDA.zeros(eltype(d_gpu), m)
    copyto!(view(d_beta, 1:m-1), view(d_gpu, n+1:n+m-1))
    
    g_dot_d = dot(g_gpu, d_gpu)
    
    alpha_candidate = CUDA.zeros(eltype(alpha_gpu), n)
    beta_candidate = CUDA.zeros(eltype(beta_gpu), m)
    
    for _ in 1:10
        alpha_candidate .= alpha_gpu .+ gamma .* d_alpha
        beta_candidate .= beta_gpu .+ gamma .* d_beta
        
        obj_new = evaluate_gradient_and_obj!(M_gpu, alpha_candidate, beta_candidate, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_scratch)
        
        if obj_new <= obj_old + c1 * gamma * g_dot_d
            return gamma, alpha_candidate, beta_candidate, obj_new
        end
        gamma *= 0.5
    end
    
    return gamma, alpha_gpu .+ gamma .* d_alpha, beta_gpu .+ gamma .* d_beta, obj_old
end

# ==============================================================================
# 4. MAIN cuRegOT SOLVER LOOP
# ==============================================================================

function curegot_solver(M_cpu::Matrix{Float32}, a_cpu::Vector{Float32}, b_cpu::Vector{Float32}, eta::Float32; 
                        k::Int = 200, 
                        S::Int = 10, 
                        max_iters::Int = 100, 
                        tol::Float64 = 1e-6)
    n, m = size(M_cpu)
    
    # Send inputs to GPU
    M_gpu = CuArray(M_cpu)
    a_gpu = CuArray(a_cpu)
    b_gpu = CuArray(b_cpu)
    
    # Initialize variables
    x_gpu = CUDA.zeros(Float32, n + m - 1)
    x_prev_gpu = CUDA.zeros(Float32, n + m - 1)
    
    alpha_gpu = CUDA.zeros(Float32, n)
    beta_gpu = CUDA.zeros(Float32, m)
    
    g_gpu = CUDA.zeros(Float32, n + m - 1)
    g_prev_gpu = CUDA.zeros(Float32, n + m - 1)
    g_scratch = CUDA.zeros(Float32, n + m - 1)
    
    # Workspace allocations
    row_sums_gpu = CUDA.zeros(Float32, n)
    col_sums_gpu = CUDA.zeros(Float32, m)
    
    # Initial evaluation
    obj = evaluate_gradient_and_obj!(M_gpu, alpha_gpu, beta_gpu, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_gpu)
    
    # State tracking variables
    F_cholesky = nothing
    active_indices = nothing
    
    println("Iter\tObjective\t\tMarginal Error")
    
    for iter in 1:max_iters
        # Calculate optimality metric (Marginal Error)
        marg_error = sum(abs.(row_sums_gpu .- a_gpu)) + sum(abs.(col_sums_gpu .- b_gpu))
        println("$iter\t$(round(obj, digits=6))\t\t$(round(marg_error, digits=6))")
        
        if marg_error < tol
            println("Convergence achieved in $iter iterations.")
            break
        end
        
        # Determine regularization scaling
        tau = min(10.0f0, norm(g_gpu))
        
        # ----------------------------------------------------------------------
        # Feature 1 & 2: Amortized Symbolic Analysis & Collaborative CPU-GPU Compute
        # ----------------------------------------------------------------------
        if (iter - 1) % S == 0
            # 1. Asynchronously dispatch sparse Cholesky structure determination to a CPU thread
            alpha_cpu = Array(alpha_gpu)
            beta_cpu = Array(beta_gpu)
            row_sums_cpu = Array(row_sums_gpu)
            col_sums_cpu = Array(col_sums_gpu)
            
            symbolic_task = Threads.@spawn begin
                H_omega, indices = build_H_omega_cpu(alpha_cpu, beta_cpu, M_cpu, eta, row_sums_cpu, col_sums_cpu, k, n, m)
                A = H_omega + tau * I
                F = cholesky(A)  # Perform full symbolic and numeric factorization
                return F, H_omega, indices
            end
            
            # 2. While CPU computes symbolic structure, run Sinkhorn candidate generation on the GPU
            alpha_s = copy(alpha_gpu)
            beta_s = copy(beta_gpu)
            run_sinkhorn_gpu!(alpha_s, beta_s, M_gpu, a_gpu, b_gpu, eta, n, m, 15)
            
            # Re-fetch CPU factorization result
            F_cholesky, H_omega, active_indices = fetch(symbolic_task)
            
        else
            # Reuse symbolic pattern: evaluate only at previous active sparsification positions
            alpha_cpu = Array(alpha_gpu)
            beta_cpu = Array(beta_gpu)
            row_sums_cpu = Array(row_sums_gpu)
            col_sums_cpu = Array(col_sums_gpu)
            
            H_omega, _ = build_H_omega_cpu(alpha_cpu, beta_cpu, M_cpu, eta, row_sums_cpu, col_sums_cpu, k, n, m; indices=active_indices)
            A = H_omega + tau * I
            
            # Perform cheap in-place numeric factorization updating using previous symbolic layout
            cholesky!(F_cholesky, A)
        end
        
        # ----------------------------------------------------------------------
        # Solve quasi-Newton search direction B d = -g via SMW formula
        # ----------------------------------------------------------------------
        g_cpu = Array(g_gpu)
        d_cpu = zeros(Float32, n + m - 1)
        
        if iter > 1
            s_minus = Array(x_gpu .- x_prev_gpu)
            y_minus = Array(g_gpu .- g_prev_gpu)
            
            # Rank-2 components (quasi-Newton BFGS correction)
            u = y_minus
            v = H_omega * s_minus .+ tau .* s_minus
            
            dot_ys = dot(y_minus, s_minus)
            dot_vs = dot(v, s_minus)
            
            if dot_ys > 1e-6 * norm(y_minus)^2
                xi = 1.0f0 / dot_ys
                zeta = -1.0f0 / dot_vs
                
                # Sherman-Morrison-Woodbury solutions
                z_g = F_cholesky \ g_cpu
                z_u = F_cholesky \ u
                z_v = F_cholesky \ v
                
                # Form 2x2 correction matrix
                M_smw = [1.0f0 + xi * dot(u, z_u)       xi * dot(u, z_v);
                         zeta * dot(v, z_u)             1.0f0 + zeta * dot(v, z_v)]
                
                rhs_smw = [xi * dot(u, z_g), zeta * dot(v, z_g)]
                c = M_smw \ rhs_smw
                
                d_cpu .= .- (z_g .- c[1] .* z_u .- c[2] .* z_v)
            else
                d_cpu .= .- (F_cholesky \ g_cpu)
            end
        else
            d_cpu .= .- (F_cholesky \ g_cpu)
        end
        
        d_gpu = CuArray(d_cpu)
        
        # Update state trackers
        copyto!(x_prev_gpu, x_gpu)
        copyto!(g_prev_gpu, g_gpu)
        
        # ----------------------------------------------------------------------
        # Candidate Evaluation & Step Selection
        # ----------------------------------------------------------------------
        # Perform line search for the Quasi-Newton Candidate
        gamma, alpha_q, beta_q, obj_q = backtracking_line_search(
            M_gpu, alpha_gpu, beta_gpu, d_gpu, g_gpu, obj, a_gpu, b_gpu, eta, n, m, row_sums_gpu, col_sums_gpu, g_scratch
        )
        
        if (iter - 1) % S == 0
            # Evaluate asynchronous Sinkhorn candidate
            obj_s = evaluate_gradient_and_obj!(M_gpu, alpha_s, beta_s, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_scratch)
            
            # Choose the candidate that yields the greater improvement
            if obj_s < obj_q
                alpha_gpu .= alpha_s
                beta_gpu .= beta_s
                obj = obj_s
            else
                alpha_gpu .= alpha_q
                beta_gpu .= beta_q
                obj = obj_q
            end
        else
            alpha_gpu .= alpha_q
            beta_gpu .= beta_q
            obj = obj_q
        end
        
        # Update dual variable representation x = (alpha, beta_{-m})
        x_gpu[1:n] .= alpha_gpu
        x_gpu[n+1:n+m-1] .= beta_gpu[1:m-1]
        
        # Evaluate active gradient representation for next iteration
        obj = evaluate_gradient_and_obj!(M_gpu, alpha_gpu, beta_gpu, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_gpu)
    end
    
    # Reconstruct and return optimal transport plan
    T_optimal = exp.((Array(alpha_gpu) .+ Array(beta_gpu)' .- M_cpu) ./ eta)
    return T_optimal
end

using CUDA
using LinearAlgebra
using DataFrames

# ==============================================================================
# CORRECTED SOLVER & MATCHING FUNCTION
# ==============================================================================

"""
Completely stable, GPU-accelerated Log-Domain Sinkhorn solver.
Uses alternating projections with the Log-Sum-Exp trick to prevent numerical overflow.
"""
function log_sinkhorn_gpu_solver(M_cpu::Matrix{Float32}, a_cpu::Vector{Float32}, b_cpu::Vector{Float32}, eta::Float32;
                                 max_iters::Int = 1000, 
                                 tol::Float64 = 1e-5)
    n, m = size(M_cpu)
    
    # Transfer distributions and costs to GPU
    M_gpu = CuArray(M_cpu)
    a_gpu = CuArray(a_cpu)
    b_gpu = CuArray(b_cpu)
    
    # Initialize dual variables
    alpha_gpu = CUDA.zeros(Float32, n)
    beta_gpu = CUDA.zeros(Float32, m)
    
    # Execution configuration
    threads = 256
    blocks_row = div(n + threads - 1, threads)
    blocks_col = div(m + threads - 1, threads)
    
    # Pre-allocate workspace for calculating marginal error on GPU
    row_sums_gpu = CUDA.zeros(Float32, n)
    col_sums_gpu = CUDA.zeros(Float32, m)
    g_scratch = CUDA.zeros(Float32, n + m - 1)
    
    println("Iter\tMarginal Error")
    for iter in 1:max_iters
        # Alternating projection updates in log-space (uses the LSE kernels)
        @cuda threads=threads blocks=blocks_row sinkhorn_row_kernel!(M_gpu, alpha_gpu, beta_gpu, eta, a_gpu, n, m)
        @cuda threads=threads blocks=blocks_col sinkhorn_col_kernel!(M_gpu, alpha_gpu, beta_gpu, eta, b_gpu, n, m)
        
        # Enforce the dual gauge constraint (beta_m = 0)
        CUDA.@allowscalar beta_gpu[m] = 0.0f0
        
        # Periodically compute marginals on the GPU to check convergence
        if iter % 10 == 0 || iter == 1
            _ = evaluate_gradient_and_obj!(M_gpu, alpha_gpu, beta_gpu, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_scratch)
            marg_error = sum(abs.(row_sums_gpu .- a_gpu)) + sum(abs.(col_sums_gpu .- b_gpu))
            
            if iter % 50 == 0 || iter == 1 || marg_error < tol
                println("$iter\t$(round(marg_error, digits=6))")
            end
            
            if marg_error < tol
                println("Log-stabilized Sinkhorn converged in $iter iterations.")
                break
            end
        end
    end
    
    T = exp.((Array(alpha_gpu) .+ Array(beta_gpu)' .- M_cpu) ./ eta)
    return T
end

function log_sinkhorn_gpu_solver_schedule(
    M_cpu::Matrix{Float32},
    a_cpu::Vector{Float32},
    b_cpu::Vector{Float32},
    eta_schedule::Vector{Float32};
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing
)
    n, m = size(M_cpu)
    M_gpu = CuArray(M_cpu)
    a_gpu = CuArray(a_cpu)
    b_gpu = CuArray(b_cpu)

    alpha_gpu = CUDA.zeros(Float32, n)
    beta_gpu = CUDA.zeros(Float32, m)

    threads = 256
    blocks_row = div(n + threads - 1, threads)
    blocks_col = div(m + threads - 1, threads)

    row_sums_gpu = CUDA.zeros(Float32, n)
    col_sums_gpu = CUDA.zeros(Float32, m)
    g_scratch = CUDA.zeros(Float32, n + m - 1)

    for eta in eta_schedule
        if !silent
            println("Eta $eta")
        end
        for iter in 1:max_iters_per_eta
            @cuda threads=threads blocks=blocks_row sinkhorn_row_kernel!(M_gpu, alpha_gpu, beta_gpu, eta, a_gpu, n, m)
            @cuda threads=threads blocks=blocks_col sinkhorn_col_kernel!(M_gpu, alpha_gpu, beta_gpu, eta, b_gpu, n, m)
            CUDA.@allowscalar beta_gpu[m] = 0.0f0
            if !isnothing(progress_callback)
                progress_callback()
            end

            if iter % 25 == 0 || iter == 1
                _ = evaluate_gradient_and_obj!(M_gpu, alpha_gpu, beta_gpu, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_scratch)
                marg_error = sum(abs.(row_sums_gpu .- a_gpu)) + sum(abs.(col_sums_gpu .- b_gpu))

                if !silent && (iter % 100 == 0 || iter == 1 || marg_error < tol)
                    println("$iter\t$(round(marg_error, digits=6))")
                end

                if marg_error < tol
                    break
                end
            end
        end
    end

    eta_final = eta_schedule[end]
    T = exp.((Array(alpha_gpu) .+ Array(beta_gpu)' .- M_cpu) ./ eta_final)
    return T
end

function log_sinkhorn_gpu_solver_schedule_optimized(
    M_cpu::Matrix{Float32},
    a_cpu::Vector{Float32},
    b_cpu::Vector{Float32},
    eta_schedule::Vector{Float32};
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    profile::Bool = false
)
    n, m = size(M_cpu)
    cpu_transpose_seconds = 0.0
    gpu_upload_allocation_seconds = 0.0
    gpu_iteration_seconds = 0.0
    dual_download_seconds = 0.0

    if profile
        Mt_cpu = nothing
        cpu_transpose_seconds = @elapsed begin
            Mt_cpu = Matrix{Float32}(transpose(M_cpu))
        end

        M_gpu = nothing
        Mt_gpu = nothing
        a_gpu = nothing
        b_gpu = nothing
        alpha_gpu = nothing
        beta_gpu = nothing
        row_sums_gpu = nothing
        col_sums_gpu = nothing
        g_scratch = nothing
        gpu_upload_allocation_seconds = @elapsed begin
            CUDA.@sync begin
                M_gpu = CuArray(M_cpu)
                Mt_gpu = CuArray(Mt_cpu)
                a_gpu = CuArray(a_cpu)
                b_gpu = CuArray(b_cpu)
                alpha_gpu = CUDA.zeros(Float32, n)
                beta_gpu = CUDA.zeros(Float32, m)
                row_sums_gpu = CUDA.zeros(Float32, n)
                col_sums_gpu = CUDA.zeros(Float32, m)
                g_scratch = CUDA.zeros(Float32, n + m - 1)
            end
        end
    else
        M_gpu = CuArray(M_cpu)
        Mt_gpu = CuArray(Matrix{Float32}(transpose(M_cpu)))
        a_gpu = CuArray(a_cpu)
        b_gpu = CuArray(b_cpu)
        alpha_gpu = CUDA.zeros(Float32, n)
        beta_gpu = CUDA.zeros(Float32, m)
        row_sums_gpu = CUDA.zeros(Float32, n)
        col_sums_gpu = CUDA.zeros(Float32, m)
        g_scratch = CUDA.zeros(Float32, n + m - 1)
    end

    threads = 256
    shmem = threads * sizeof(Float32)

    last_marg_error = Inf
    iterations_completed = 0

    solver_loop = () -> begin
        for eta in eta_schedule
            if !silent
                println("Eta $eta")
            end
            for iter in 1:max_iters_per_eta
                @cuda threads=threads blocks=n shmem=shmem sinkhorn_row_block_kernel!(Mt_gpu, alpha_gpu, beta_gpu, eta, a_gpu, n, m)
                @cuda threads=threads blocks=m shmem=shmem sinkhorn_col_block_kernel!(M_gpu, alpha_gpu, beta_gpu, eta, b_gpu, n, m)
                CUDA.@allowscalar beta_gpu[m] = 0.0f0
                iterations_completed += 1

                if !isnothing(progress_callback)
                    progress_callback()
                end

                if iter % check_every == 0 || iter == 1 || iter == max_iters_per_eta
                    _ = evaluate_gradient_and_obj!(M_gpu, alpha_gpu, beta_gpu, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_scratch)
                    last_marg_error = sum(abs.(row_sums_gpu .- a_gpu)) + sum(abs.(col_sums_gpu .- b_gpu))

                    if !silent && (iter % (5 * check_every) == 0 || iter == 1 || last_marg_error < tol)
                        println("$iter\t$(round(last_marg_error, digits=6))")
                    end

                    if !isfinite(last_marg_error)
                        error("Non-finite Sinkhorn marginal error at eta=$eta iteration=$iter.")
                    end

                    if last_marg_error < tol
                        break
                    end
                end
            end
        end
    end

    if profile
        gpu_iteration_seconds = @elapsed begin
            CUDA.@sync solver_loop()
        end
    else
        solver_loop()
    end

    if profile
        alpha_cpu = nothing
        beta_cpu = nothing
        dual_download_seconds = @elapsed begin
            CUDA.@sync begin
                alpha_cpu = Array(alpha_gpu)
                beta_cpu = Array(beta_gpu)
            end
        end
    else
        alpha_cpu = Array(alpha_gpu)
        beta_cpu = Array(beta_gpu)
    end
    if any(!isfinite, alpha_cpu) || any(!isfinite, beta_cpu)
        error("Non-finite Sinkhorn dual potential.")
    end

    result = (
        alpha = alpha_cpu,
        beta = beta_cpu,
        eta = eta_schedule[end],
        marginal_error = last_marg_error,
        iterations = iterations_completed,
    )

    if profile
        return merge(result, (timings = (
            cpu_transpose_seconds = cpu_transpose_seconds,
            gpu_upload_allocation_seconds = gpu_upload_allocation_seconds,
            gpu_iteration_seconds = gpu_iteration_seconds,
            dual_download_seconds = dual_download_seconds,
        ),))
    end

    return result
end

function log_sinkhorn_gpu_solver_schedule_optimized_each_eta(
    M_cpu::Matrix{Float32},
    a_cpu::Vector{Float32},
    b_cpu::Vector{Float32},
    eta_schedule::Vector{Float32};
    candidate_etas::Vector{Float32} = eta_schedule,
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    stage_callback::Union{Nothing, Function} = nothing,
    profile::Bool = false
)
    n, m = size(M_cpu)
    if isempty(eta_schedule)
        error("eta_schedule cannot be empty.")
    end
    if isempty(candidate_etas)
        error("candidate_etas cannot be empty.")
    end

    cpu_transpose_seconds = 0.0
    gpu_upload_allocation_seconds = 0.0
    gpu_iteration_seconds = 0.0
    dual_download_seconds = 0.0

    if profile
        Mt_cpu = nothing
        cpu_transpose_seconds = @elapsed begin
            Mt_cpu = Matrix{Float32}(transpose(M_cpu))
        end

        M_gpu = nothing
        Mt_gpu = nothing
        a_gpu = nothing
        b_gpu = nothing
        alpha_gpu = nothing
        beta_gpu = nothing
        row_sums_gpu = nothing
        col_sums_gpu = nothing
        g_scratch = nothing
        gpu_upload_allocation_seconds = @elapsed begin
            CUDA.@sync begin
                M_gpu = CuArray(M_cpu)
                Mt_gpu = CuArray(Mt_cpu)
                a_gpu = CuArray(a_cpu)
                b_gpu = CuArray(b_cpu)
                alpha_gpu = CUDA.zeros(Float32, n)
                beta_gpu = CUDA.zeros(Float32, m)
                row_sums_gpu = CUDA.zeros(Float32, n)
                col_sums_gpu = CUDA.zeros(Float32, m)
                g_scratch = CUDA.zeros(Float32, n + m - 1)
            end
        end
    else
        M_gpu = CuArray(M_cpu)
        Mt_gpu = CuArray(Matrix{Float32}(transpose(M_cpu)))
        a_gpu = CuArray(a_cpu)
        b_gpu = CuArray(b_cpu)
        alpha_gpu = CUDA.zeros(Float32, n)
        beta_gpu = CUDA.zeros(Float32, m)
        row_sums_gpu = CUDA.zeros(Float32, n)
        col_sums_gpu = CUDA.zeros(Float32, m)
        g_scratch = CUDA.zeros(Float32, n + m - 1)
    end

    threads = 256
    shmem = threads * sizeof(Float32)
    candidate_set = Set(candidate_etas)

    last_marg_error = Inf
    iterations_completed = 0
    last_result = nothing

    for eta in eta_schedule
        if !silent
            println("Eta $eta")
        end

        eta_loop = () -> begin
            for iter in 1:max_iters_per_eta
                @cuda threads=threads blocks=n shmem=shmem sinkhorn_row_block_kernel!(Mt_gpu, alpha_gpu, beta_gpu, eta, a_gpu, n, m)
                @cuda threads=threads blocks=m shmem=shmem sinkhorn_col_block_kernel!(M_gpu, alpha_gpu, beta_gpu, eta, b_gpu, n, m)
                CUDA.@allowscalar beta_gpu[m] = 0.0f0
                iterations_completed += 1

                if !isnothing(progress_callback)
                    progress_callback()
                end

                if iter % check_every == 0 || iter == 1 || iter == max_iters_per_eta
                    _ = evaluate_gradient_and_obj!(M_gpu, alpha_gpu, beta_gpu, eta, row_sums_gpu, col_sums_gpu, a_gpu, b_gpu, n, m, g_scratch)
                    last_marg_error = sum(abs.(row_sums_gpu .- a_gpu)) + sum(abs.(col_sums_gpu .- b_gpu))

                    if !silent && (iter % (5 * check_every) == 0 || iter == 1 || last_marg_error < tol)
                        println("$iter\t$(round(last_marg_error, digits=6))")
                    end

                    if !isfinite(last_marg_error)
                        error("Non-finite Sinkhorn marginal error at eta=$eta iteration=$iter.")
                    end

                    if last_marg_error < tol
                        break
                    end
                end
            end
        end

        if profile
            gpu_iteration_seconds += @elapsed begin
                CUDA.@sync eta_loop()
            end
        else
            eta_loop()
        end

        if eta in candidate_set
            if profile
                alpha_cpu = nothing
                beta_cpu = nothing
                dual_download_seconds += @elapsed begin
                    CUDA.@sync begin
                        alpha_cpu = Array(alpha_gpu)
                        beta_cpu = Array(beta_gpu)
                    end
                end
            else
                alpha_cpu = Array(alpha_gpu)
                beta_cpu = Array(beta_gpu)
            end
            if any(!isfinite, alpha_cpu) || any(!isfinite, beta_cpu)
                error("Non-finite Sinkhorn dual potential at eta=$eta.")
            end

            result = (
                alpha = alpha_cpu,
                beta = beta_cpu,
                eta = eta,
                marginal_error = last_marg_error,
                iterations = iterations_completed,
            )

            if profile
                result = merge(result, (timings = (
                    cpu_transpose_seconds = cpu_transpose_seconds,
                    gpu_upload_allocation_seconds = gpu_upload_allocation_seconds,
                    gpu_iteration_seconds = gpu_iteration_seconds,
                    dual_download_seconds = dual_download_seconds,
                ),))
            end

            last_result = result
            if !isnothing(stage_callback) && stage_callback(result)
                return result
            end
        end
    end

    if isnothing(last_result)
        error("No requested eta candidate was present in eta_schedule.")
    end

    return last_result
end

function extract_sinkhorn_matches(
    M_cpu::Matrix{Float32},
    alpha_cpu::Vector{Float32},
    beta_cpu::Vector{Float32},
    eta::Float32,
    a_cpu::Vector{Float32},
    total_pop,
    pop_clean::DataFrame,
    cartogram::DataFrame;
    cumulative_weight::Float64 = 0.995,
    min_weight::Float64 = 1e-4,
    min_output_neighbors::Int = 1,
    max_output_neighbors::Union{Nothing, Int} = nothing
)
    n, m = size(M_cpu)
    assigned_h3 = Vector{eltype(pop_clean.h3)}()
    assigned_x = Vector{eltype(cartogram.x)}()
    assigned_y = Vector{eltype(cartogram.y)}()
    assigned_weight = Vector{Float64}()
    assigned_overlap = Vector{Float64}()

    max_keep = isnothing(max_output_neighbors) ? m : min(max_output_neighbors, m)
    row_mass = Vector{Float32}(undef, m)

    for i in 1:n
        @inbounds for j in 1:m
            row_mass[j] = exp((alpha_cpu[i] + beta_cpu[j] - M_cpu[i, j]) / eta)
        end
        if any(!isfinite, row_mass)
            error("Non-finite reconstructed Sinkhorn row at source row $i.")
        end

        order = sortperm(row_mass, rev=true)
        cumulative = 0.0
        kept = 0

        for j in order
            mass = Float64(row_mass[j])
            if mass <= 0
                break
            end

            weight = mass / Float64(a_cpu[i])
            if kept >= min_output_neighbors && cumulative >= cumulative_weight && weight < min_weight
                break
            end

            overlap = mass * total_pop
            push!(assigned_h3, pop_clean.h3[i])
            push!(assigned_x, cartogram.x[j])
            push!(assigned_y, cartogram.y[j])
            push!(assigned_weight, weight)
            push!(assigned_overlap, overlap)

            cumulative += weight
            kept += 1

            if kept >= max_keep || (kept >= min_output_neighbors && cumulative >= cumulative_weight)
                break
            end
        end
    end

    return DataFrame(
        h3 = assigned_h3,
        x = assigned_x,
        y = assigned_y,
        weight = assigned_weight,
        overlap = assigned_overlap
    )
end

function validate_sinkhorn2_extraction_args(
    eta_schedule::Vector{Float32},
    cumulative_weight::Float64,
    min_output_neighbors::Int
)
    if isempty(eta_schedule)
        error("eta_schedule cannot be empty.")
    end
    if !(0.0 < cumulative_weight <= 1.0)
        error("cumulative_weight must be in (0, 1].")
    end
    if min_output_neighbors <= 0
        error("min_output_neighbors must be positive.")
    end
end

function prepare_sinkhorn2_problem(
    population::DataFrame,
    cartogram::DataFrame;
    cost_power::Float64 = 2.0,
    normalize_cost::Bool = true,
    profile::Bool = false
)
    input_cleanup_seconds = 0.0
    coordinate_scaling_seconds = 0.0
    cost_matrix_fill_seconds = 0.0
    cost_normalization_seconds = 0.0
    mass_vector_seconds = 0.0

    pop_clean = nothing
    targets = 0
    sources = 0
    total_pop = 0.0
    input_cleanup_seconds = @elapsed begin
        pop_clean = filter(row -> row.population > 0.0, population)
        targets = size(cartogram, 1)
        sources = size(pop_clean, 1)

        if sources == 0 || targets == 0
            error("Input population or cartogram dataframe is empty.")
        end
        if cost_power <= 0
            error("cost_power must be positive.")
        end

        total_pop = sum(pop_clean.population)
    end

    pop_carto_x = nothing
    pop_carto_y = nothing
    carto_step_x = 1.0
    carto_step_y = 1.0
    coordinate_scaling_seconds = @elapsed begin
        lat_min, lat_max = minimum(pop_clean.y), maximum(pop_clean.y)
        lon_min, lon_max = minimum(pop_clean.x), maximum(pop_clean.x)
        x_min, max_x = minimum(cartogram.x), maximum(cartogram.x)
        y_min, max_y = minimum(cartogram.y), maximum(cartogram.y)

        lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
        lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
        x_span = (max_x - x_min) > 0 ? (max_x - x_min) : 1.0
        y_span = (max_y - y_min) > 0 ? (max_y - y_min) : 1.0

        pop_norm_x = (pop_clean.x .- lon_min) ./ lon_span
        pop_norm_y = (pop_clean.y .- lat_min) ./ lat_span
        pop_carto_x = x_min .+ pop_norm_x .* x_span
        pop_carto_y = y_min .+ pop_norm_y .* y_span

        unique_carto_x = sort(unique(cartogram.x))
        unique_carto_y = sort(unique(cartogram.y))
        carto_step_x = length(unique_carto_x) > 1 ? minimum(diff(unique_carto_x)) : 1.0
        carto_step_y = length(unique_carto_y) > 1 ? minimum(diff(unique_carto_y)) : 1.0
    end

    cost = Matrix{Float32}(undef, sources, targets)
    cost_matrix_fill_seconds = @elapsed begin
        Threads.@threads for i in 1:sources
            px, py = pop_carto_x[i], pop_carto_y[i]
            for j in 1:targets
                dx = (px - cartogram.x[j]) / carto_step_x
                dy = (py - cartogram.y[j]) / carto_step_y
                d = sqrt(dx^2 + dy^2)
                cost[i, j] = Float32(d^cost_power)
            end
        end
    end

    if normalize_cost
        cost_normalization_seconds = @elapsed begin
            max_cost = maximum(cost)
            if max_cost > 0
                cost ./= max_cost
            end
        end
    end

    source_mass = Vector{Float32}(undef, sources)
    target_mass = Vector{Float32}(undef, targets)
    mass_vector_seconds = @elapsed begin
        source_mass = Vector{Float32}(pop_clean.population ./ total_pop)
        target_mass = fill(1.0f0 / targets, targets)
    end

    return (
        cost = cost,
        source_mass = source_mass,
        target_mass = target_mass,
        pop_clean = pop_clean,
        cartogram = cartogram,
        total_pop = total_pop,
        sources = sources,
        targets = targets,
        timings = (
            input_cleanup_seconds = input_cleanup_seconds,
            coordinate_scaling_seconds = coordinate_scaling_seconds,
            cost_matrix_fill_seconds = cost_matrix_fill_seconds,
            cost_normalization_seconds = cost_normalization_seconds,
            mass_vector_seconds = mass_vector_seconds,
        ),
    )
end

function solve_prepared_sinkhorn2_problem(
    prepared,
    eta_schedule::Vector{Float32};
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    profile::Bool = false
)
    if isempty(eta_schedule)
        error("eta_schedule cannot be empty.")
    end

    return log_sinkhorn_gpu_solver_schedule_optimized(
        prepared.cost,
        prepared.source_mass,
        prepared.target_mass,
        eta_schedule;
        max_iters_per_eta=max_iters_per_eta,
        tol=tol,
        check_every=check_every,
        silent=silent,
        progress_callback=progress_callback,
        profile=profile
    )
end

function extract_prepared_sinkhorn2_matches(
    prepared,
    result;
    cumulative_weight::Float64 = 0.995,
    min_weight::Float64 = 1e-4,
    min_output_neighbors::Int = 1,
    max_output_neighbors::Union{Nothing, Int} = nothing
)
    return extract_sinkhorn_matches(
        prepared.cost,
        result.alpha,
        result.beta,
        result.eta,
        prepared.source_mass,
        prepared.total_pop,
        prepared.pop_clean,
        prepared.cartogram;
        cumulative_weight=cumulative_weight,
        min_weight=min_weight,
        min_output_neighbors=min_output_neighbors,
        max_output_neighbors=max_output_neighbors
    )
end

"""
Dense balanced Sinkhorn matching with cartogram-cell radial costs.

This is intended as the main modelling experiment for coherent cartogram
matching: the solver remains balanced and dense, while the returned dataframe is
sparsified per source by cumulative transported mass.
"""
function match_h3_to_cartogram_sinkhorn2(
    population::DataFrame,
    cartogram::DataFrame;
    cost_power::Float64 = 2.0,
    eta_schedule::Vector{Float32} = Float32[0.05, 0.02, 0.01, 0.005],
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    cumulative_weight::Float64 = 0.995,
    min_weight::Float64 = 1e-4,
    min_output_neighbors::Int = 1,
    max_output_neighbors::Union{Nothing, Int} = nothing,
    normalize_cost::Bool = true,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    return_metadata::Bool = false,
    profile::Bool = false
)
    validate_sinkhorn2_extraction_args(eta_schedule, cumulative_weight, min_output_neighbors)
    total_wall_start = time()
    solver_total_seconds = 0.0
    sparse_extraction_seconds = 0.0

    prepared = prepare_sinkhorn2_problem(
        population,
        cartogram;
        cost_power=cost_power,
        normalize_cost=normalize_cost,
        profile=profile
    )

    result = nothing
    solver_total_seconds = @elapsed begin
        result = solve_prepared_sinkhorn2_problem(
            prepared,
            eta_schedule;
            max_iters_per_eta=max_iters_per_eta,
            tol=tol,
            check_every=check_every,
            silent=silent,
            progress_callback=progress_callback,
            profile=profile
        )
    end

    df = nothing
    sparse_extraction_seconds = @elapsed begin
        df = extract_prepared_sinkhorn2_matches(
            prepared,
            result;
            cumulative_weight=cumulative_weight,
            min_weight=min_weight,
            min_output_neighbors=min_output_neighbors,
            max_output_neighbors=max_output_neighbors
        )
    end

    metadata = (
        final_eta = result.eta,
        marginal_error = result.marginal_error,
        iterations = result.iterations,
        rows = nrow(df),
        sources = prepared.sources,
        targets = prepared.targets,
    )

    if profile
        solver_timings = result.timings
        metadata = merge(metadata, (timings = merge(prepared.timings, (
            total_wall_seconds = time() - total_wall_start,
            solver_total_seconds = solver_total_seconds,
        ), solver_timings, (
            sparse_extraction_seconds = sparse_extraction_seconds,
        )),))
    end

    return return_metadata ? (df, metadata) : df
end

function eta_schedule_to(final_eta::Float32; base_schedule::Vector{Float32}=Float32[0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005])
    schedule = Float32[eta for eta in base_schedule if eta >= final_eta]
    if isempty(schedule) || schedule[end] != final_eta
        push!(schedule, final_eta)
    end
    return unique(schedule)
end

function eta_continuation_schedule(
    candidate_final_etas::Vector{Float32};
    base_schedule::Vector{Float32}=Float32[0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005]
)
    if isempty(candidate_final_etas)
        error("candidate_final_etas cannot be empty.")
    end

    min_eta = minimum(candidate_final_etas)
    schedule = Float32[eta for eta in base_schedule if eta >= min_eta]
    append!(schedule, candidate_final_etas)
    schedule = sort(collect(Set(schedule)), rev=true)
    return Float32[schedule...]
end

function match_prepared_h3_to_cartogram_sinkhorn2_auto(
    prepared;
    target_rows_multiplier::Float64 = 10.0,
    candidate_final_etas::Vector{Float32} = Float32[0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005],
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    return_metadata::Bool = false,
    cumulative_weight::Float64 = 0.995,
    min_weight::Float64 = 1e-4,
    min_output_neighbors::Int = 1,
    max_output_neighbors::Union{Nothing, Int} = nothing,
    profile::Bool = false,
    total_wall_start::Float64 = time(),
)
    if isempty(candidate_final_etas)
        error("candidate_final_etas cannot be empty.")
    end
    validate_sinkhorn2_extraction_args(Float32[1.0], cumulative_weight, min_output_neighbors)

    target_rows = round(Int, target_rows_multiplier * (prepared.sources + prepared.targets))

    best_df = nothing
    best_meta = nothing
    failed = NamedTuple[]
    candidate_etas = sort(collect(Set(candidate_final_etas)), rev=true)
    schedule = eta_continuation_schedule(candidate_etas)
    current_eta = Ref{Float32}(NaN32)
    solver_total_seconds = 0.0

    try
        solver_total_seconds = @elapsed begin
            log_sinkhorn_gpu_solver_schedule_optimized_each_eta(
                prepared.cost,
                prepared.source_mass,
                prepared.target_mass,
                schedule;
                candidate_etas=candidate_etas,
                max_iters_per_eta=max_iters_per_eta,
                tol=tol,
                check_every=check_every,
                silent=silent,
                progress_callback=progress_callback,
                profile=profile,
                stage_callback = result -> begin
                    current_eta[] = result.eta
                    if !isfinite(result.marginal_error)
                        error("Non-finite marginal error for final eta $(result.eta).")
                    end

                    df = nothing
                    sparse_extraction_seconds = @elapsed begin
                        df = extract_prepared_sinkhorn2_matches(
                            prepared,
                            result;
                            cumulative_weight=cumulative_weight,
                            min_weight=min_weight,
                            min_output_neighbors=min_output_neighbors,
                            max_output_neighbors=max_output_neighbors
                        )
                    end

                    meta = (
                        final_eta = result.eta,
                        marginal_error = result.marginal_error,
                        iterations = result.iterations,
                        rows = nrow(df),
                        sources = prepared.sources,
                        targets = prepared.targets,
                    )

                    if profile
                        meta = merge(meta, (timings = merge(prepared.timings, (
                            total_wall_seconds = time() - total_wall_start,
                            solver_total_seconds = solver_total_seconds,
                        ), result.timings, (
                            sparse_extraction_seconds = sparse_extraction_seconds,
                        )),))
                    end

                    tuned_meta = merge(meta, (
                        target_rows=target_rows,
                        row_error=abs(meta.rows - target_rows),
                        failed_candidates=failed,
                    ))

                    if isnothing(best_meta) || tuned_meta.row_error < best_meta.row_error
                        best_df = df
                        best_meta = tuned_meta
                    end

                    return meta.rows <= target_rows
                end
            )
        end
    catch e
        if e isa InterruptException
            rethrow()
        end
        push!(failed, (eta=current_eta[], error=sprint(showerror, e)))
        if !isnothing(best_meta)
            best_meta = merge(best_meta, (failed_candidates=failed,))
        end
    end

    if isnothing(best_df)
        error("No stable Sinkhorn eta candidate found. Failed candidates: $failed")
    end

    if profile && !isnothing(best_meta)
        best_meta = merge(best_meta, (timings = merge(best_meta.timings, (
            total_wall_seconds = time() - total_wall_start,
            solver_total_seconds = solver_total_seconds,
        )),))
    end

    return return_metadata ? (best_df, best_meta) : best_df
end

function match_prepared_h3_to_cartogram_sinkhorn2_auto_repeated_schedule_reference(
    prepared;
    target_rows_multiplier::Float64 = 10.0,
    candidate_final_etas::Vector{Float32} = Float32[0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005],
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    return_metadata::Bool = false,
    cumulative_weight::Float64 = 0.995,
    min_weight::Float64 = 1e-4,
    min_output_neighbors::Int = 1,
    max_output_neighbors::Union{Nothing, Int} = nothing,
    profile::Bool = false,
    total_wall_start::Float64 = time(),
)
    if isempty(candidate_final_etas)
        error("candidate_final_etas cannot be empty.")
    end
    validate_sinkhorn2_extraction_args(Float32[1.0], cumulative_weight, min_output_neighbors)

    target_rows = round(Int, target_rows_multiplier * (prepared.sources + prepared.targets))

    best_df = nothing
    best_meta = nothing
    failed = NamedTuple[]

    for final_eta in candidate_final_etas
        schedule = eta_schedule_to(final_eta)
        try
            result = nothing
            solver_total_seconds = @elapsed begin
                result = solve_prepared_sinkhorn2_problem(
                    prepared,
                    schedule;
                    max_iters_per_eta=max_iters_per_eta,
                    tol=tol,
                    check_every=check_every,
                    silent=silent,
                    progress_callback=progress_callback,
                    profile=profile
                )
            end

            if !isfinite(result.marginal_error)
                error("Non-finite marginal error for final eta $final_eta.")
            end

            df = nothing
            sparse_extraction_seconds = @elapsed begin
                df = extract_prepared_sinkhorn2_matches(
                    prepared,
                    result;
                    cumulative_weight=cumulative_weight,
                    min_weight=min_weight,
                    min_output_neighbors=min_output_neighbors,
                    max_output_neighbors=max_output_neighbors
                )
            end

            meta = (
                final_eta = result.eta,
                marginal_error = result.marginal_error,
                iterations = result.iterations,
                rows = nrow(df),
                sources = prepared.sources,
                targets = prepared.targets,
            )

            if profile
                meta = merge(meta, (timings = merge(prepared.timings, (
                    total_wall_seconds = time() - total_wall_start,
                    solver_total_seconds = solver_total_seconds,
                ), result.timings, (
                    sparse_extraction_seconds = sparse_extraction_seconds,
                )),))
            end

            tuned_meta = merge(meta, (
                target_rows=target_rows,
                row_error=abs(meta.rows - target_rows),
                failed_candidates=failed,
            ))

            if isnothing(best_meta) || tuned_meta.row_error < best_meta.row_error
                best_df = df
                best_meta = tuned_meta
            end

            if meta.rows <= target_rows
                return return_metadata ? (df, tuned_meta) : df
            end
        catch e
            if e isa InterruptException
                rethrow()
            end
            push!(failed, (eta=final_eta, error=sprint(showerror, e)))
            if !isnothing(best_df)
                break
            end
        end
    end

    if isnothing(best_df)
        error("No stable Sinkhorn eta candidate found. Failed candidates: $failed")
    end

    return return_metadata ? (best_df, best_meta) : best_df
end

function match_h3_to_cartogram_sinkhorn2_auto(
    population::DataFrame,
    cartogram::DataFrame;
    target_rows_multiplier::Float64 = 10.0,
    candidate_final_etas::Vector{Float32} = Float32[0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005],
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    return_metadata::Bool = false,
    cost_power::Float64 = 2.0,
    cumulative_weight::Float64 = 0.995,
    min_weight::Float64 = 1e-4,
    min_output_neighbors::Int = 1,
    max_output_neighbors::Union{Nothing, Int} = nothing,
    normalize_cost::Bool = true,
    profile::Bool = false,
    kwargs...
)
    if !isempty(kwargs)
        error("Unsupported keyword(s) for match_h3_to_cartogram_sinkhorn2_auto: $(keys(kwargs))")
    end
    if isempty(candidate_final_etas)
        error("candidate_final_etas cannot be empty.")
    end
    validate_sinkhorn2_extraction_args(Float32[1.0], cumulative_weight, min_output_neighbors)

    total_wall_start = time()
    prepared = prepare_sinkhorn2_problem(
        population,
        cartogram;
        cost_power=cost_power,
        normalize_cost=normalize_cost,
        profile=profile
    )

    return match_prepared_h3_to_cartogram_sinkhorn2_auto(
        prepared;
        target_rows_multiplier=target_rows_multiplier,
        candidate_final_etas=candidate_final_etas,
        max_iters_per_eta=max_iters_per_eta,
        tol=tol,
        check_every=check_every,
        silent=silent,
        progress_callback=progress_callback,
        return_metadata=return_metadata,
        cumulative_weight=cumulative_weight,
        min_weight=min_weight,
        min_output_neighbors=min_output_neighbors,
        max_output_neighbors=max_output_neighbors,
        profile=profile,
        total_wall_start=total_wall_start,
    )
end

function match_h3_to_cartogram_sinkhorn2_auto_repeated_prepare_reference(
    population::DataFrame,
    cartogram::DataFrame;
    target_rows_multiplier::Float64 = 10.0,
    candidate_final_etas::Vector{Float32} = Float32[0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005],
    max_iters_per_eta::Int = 1000,
    tol::Float64 = 1e-5,
    check_every::Int = 100,
    silent::Bool = true,
    progress_callback::Union{Nothing, Function} = nothing,
    return_metadata::Bool = false,
    kwargs...
)
    M = nrow(filter(row -> row.population > 0.0, population))
    N = nrow(cartogram)
    target_rows = round(Int, target_rows_multiplier * (M + N))

    best_df = nothing
    best_meta = nothing
    failed = NamedTuple[]

    for final_eta in candidate_final_etas
        schedule = eta_schedule_to(final_eta)
        try
            df, meta = match_h3_to_cartogram_sinkhorn2(
                population,
                cartogram;
                eta_schedule=schedule,
                max_iters_per_eta=max_iters_per_eta,
                tol=tol,
                check_every=check_every,
                silent=silent,
                progress_callback=progress_callback,
                return_metadata=true,
                kwargs...
            )

            if !isfinite(meta.marginal_error)
                error("Non-finite marginal error for final eta $final_eta.")
            end

            tuned_meta = merge(meta, (
                target_rows=target_rows,
                row_error=abs(meta.rows - target_rows),
                failed_candidates=failed,
            ))

            if isnothing(best_meta) || tuned_meta.row_error < best_meta.row_error
                best_df = df
                best_meta = tuned_meta
            end

            if meta.rows <= target_rows
                return return_metadata ? (df, tuned_meta) : df
            end
        catch e
            if e isa InterruptException
                rethrow()
            end
            push!(failed, (eta=final_eta, error=sprint(showerror, e)))
            if !isnothing(best_df)
                break
            end
        end
    end

    if isnothing(best_df)
        error("No stable Sinkhorn eta candidate found. Failed candidates: $failed")
    end

    return return_metadata ? (best_df, best_meta) : best_df
end

function match_h3_to_cartogram_stable(
    population::DataFrame, 
    cartogram::DataFrame; 
    eta::Float32 = 0.005f0,       # Stable down to extremely small values now
    max_iters::Int = 1000,
    tol::Float64 = 1e-5,
    threshold::Float64 = 1e-5
)
    pop_clean = filter(row -> row.population > 0.0, population)
    N = size(cartogram, 1)
    M = size(pop_clean, 1)
    
    if M == 0 || N == 0
        error("Input population or cartogram dataframe is empty.")
    end
    
    total_pop = sum(pop_clean.population)
    
    # --- Normalized Cost Matrix ---
    lat_min, lat_max = minimum(pop_clean.y), maximum(pop_clean.y)
    lon_min, lon_max = minimum(pop_clean.x), maximum(pop_clean.x)
    x_min, max_x = minimum(cartogram.x), maximum(cartogram.x)
    y_min, max_y = minimum(cartogram.y), maximum(cartogram.y)
    
    lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
    lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
    x_span = (max_x - x_min) > 0 ? (max_x - x_min) : 1.0
    y_span = (max_y - y_min) > 0 ? (max_y - y_min) : 1.0
    
    pop_norm_x = (pop_clean.x .- lon_min) ./ lon_span
    pop_norm_y = (pop_clean.y .- lat_min) ./ lat_span
    carto_norm_x = (cartogram.x .- x_min) ./ x_span
    carto_norm_y = (cartogram.y .- y_min) ./ y_span
    
    M_cpu = Matrix{Float32}(undef, M, N)
    Threads.@threads for i in 1:M
        px, py = pop_norm_x[i], pop_norm_y[i]
        for j in 1:N
            M_cpu[i, j] = sqrt((px - carto_norm_x[j])^2 + (py - carto_norm_y[j])^2)
        end
    end
    M_cpu ./= maximum(M_cpu)
    
    a_cpu = Vector{Float32}(pop_clean.population ./ total_pop)
    b_cpu = fill(1.0f0 / N, N) # CHANGED from 1.0f32 to 1.0f0
    
    # --- Run Solver ---
    T = log_sinkhorn_gpu_solver(M_cpu, a_cpu, b_cpu, eta; max_iters=max_iters, tol=tol)
    
    # --- Reconstruct Absolute Mass Outputs ---
    T_abs = T .* total_pop
    
    assigned_h3 = Vector{UInt64}()
    assigned_x = Vector{eltype(cartogram.x)}()
    assigned_y = Vector{eltype(cartogram.y)}()
    assigned_weight = Vector{Float64}()
    assigned_overlap = Vector{Float64}()
    
    for j in 1:N, i in 1:M
        overlap = T_abs[i, j]
        if overlap > threshold
            h3_pop = pop_clean.population[i]
            weight = h3_pop > 0 ? (overlap / h3_pop) : 0.0
            
            push!(assigned_h3, pop_clean.h3[i])
            push!(assigned_x, cartogram.x[j])
            push!(assigned_y, cartogram.y[j])
            push!(assigned_weight, weight)
            push!(assigned_overlap, overlap)
        end
    end
    
    return DataFrame(
        h3 = assigned_h3, 
        x = assigned_x, 
        y = assigned_y, 
        weight = assigned_weight, 
        overlap = assigned_overlap
    )
end

"""
Distributes population from H3 cells to a cartogram grid using GPU-accelerated 
entropic-regularized optimal transport.
"""
function match_h3_to_cartogram_curegot(
    population::DataFrame, 
    cartogram::DataFrame; 
    eta::Float32 = 0.005f0,       # Entropic regularization parameter
    k::Int = 2000,                # Sparsified Cholesky parameter (top-k entries of T)
    S::Int = 10,                  # Amortized symbolic factorization interval
    max_iters::Int = 100,         # Maximum iterations
    tol::Float64 = 1e-5,          # Tolerance for convergence (marginal error)
    threshold::Float64 = 1e-5     # Minimum overlap to include in the output DataFrame
)
    pop_clean = filter(row -> row.population > 0.0, population)
    
    N = size(cartogram, 1) # Target cells
    M = size(pop_clean, 1) # Source cells
    
    if M == 0 || N == 0
        error("Input population or cartogram dataframe is empty.")
    end
    
    total_pop = sum(pop_clean.population)
    
    # --- 1. Map Coordinates and Normalize Spans ---
    lat_min, lat_max = minimum(pop_clean.y), maximum(pop_clean.y)
    lon_min, lon_max = minimum(pop_clean.x), maximum(pop_clean.x)
    x_min, max_x = minimum(cartogram.x), maximum(cartogram.x)
    y_min, max_y = minimum(cartogram.y), maximum(cartogram.y)
    
    lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
    lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
    x_span = (max_x - x_min) > 0 ? (max_x - x_min) : 1.0
    y_span = (max_y - y_min) > 0 ? (max_y - y_min) : 1.0
    
    pop_norm_x = (pop_clean.x .- lon_min) ./ lon_span
    pop_norm_y = (pop_clean.y .- lat_min) ./ lat_span
    
    carto_norm_x = (cartogram.x .- x_min) ./ x_span
    carto_norm_y = (cartogram.y .- y_min) ./ y_span
    
    # --- 2. Construct the Distance/Cost Matrix ---
    # Constructing a full dense cost matrix on the CPU
    M_cpu = Matrix{Float32}(undef, M, N)
    Threads.@threads for i in 1:M
        px, py = pop_norm_x[i], pop_norm_y[i]
        for j in 1:N
            # Euclidean distance matching the original logic
            M_cpu[i, j] = sqrt((px - carto_norm_x[j])^2 + (py - carto_norm_y[j])^2)
        end
    end
    
    # Normalize the cost matrix by its maximum value to keep eta comparable
    M_cpu ./= maximum(M_cpu)
    
    # --- 3. Prepare Marginal Probability Vectors ---
    a_cpu = Vector{Float32}(pop_clean.population ./ total_pop)
    b_cpu = fill(1.0f0 / N, N) # Targets uniform distribution to enforce even spatial loading
    
    # --- 4. Run the GPU-Accelerated Solver ---
    T = curegot_solver(M_cpu, a_cpu, b_cpu, eta; k=k, S=S, max_iters=max_iters, tol=tol)
    
    # --- 5. Extract and Reconstruct Absolute Mass Outputs ---
    T_abs = T .* total_pop
    
    assigned_h3 = Vector{UInt64}()
    assigned_x = Vector{eltype(cartogram.x)}()
    assigned_y = Vector{eltype(cartogram.y)}()
    assigned_weight = Vector{Float64}()
    assigned_overlap = Vector{Float64}()
    
    # Filter and capture non-negligible transport contributions
    for j in 1:N
        for i in 1:M
            overlap = T_abs[i, j]
            if overlap > threshold
                h3_pop = pop_clean.population[i]
                weight = h3_pop > 0 ? (overlap / h3_pop) : 0.0
                
                push!(assigned_h3, pop_clean.h3[i])
                push!(assigned_x, cartogram.x[j])
                push!(assigned_y, cartogram.y[j])
                push!(assigned_weight, weight)
                push!(assigned_overlap, overlap)
            end
        end
    end
    
    return DataFrame(
        h3 = assigned_h3, 
        x = assigned_x, 
        y = assigned_y, 
        weight = assigned_weight, 
        overlap = assigned_overlap
    )
end

"""
Distributes population from H3 cells to a cartogram grid with exact uniform target
loads, using an adaptive nearest-neighbor edge set.

For each source cell, the candidate count is based on the minimum number of
uniform target cells needed to hold its mass, multiplied by `oversample`.
"""
function match_h3_to_cartogram_adaptive_ot(
    population,
    cartogram;
    oversample::Float64 = 2.0,
    min_neighbors::Int = 10,
    target_neighbors::Int = 10,
    max_neighbors::Union{Nothing, Int} = nothing,
    retry_factor::Float64 = 1.5,
    max_retries::Int = 3,
    full_fallback_max_edges::Int = 0,
    uniform_mode::Symbol = :soft,
    uniform_penalty::Float64 = 100_000.0,
    uniform_rel_tol::Float64 = 0.01,
    threshold::Float64 = 1e-5,
    silent::Bool = true
)
    pop_clean = filter(row -> row.population > 0.0, population)

    N = size(cartogram, 1)
    M = size(pop_clean, 1)

    if M == 0 || N == 0
        error("Input population or cartogram dataframe is empty.")
    end
    if oversample <= 0
        error("oversample must be positive.")
    end
    if min_neighbors <= 0
        error("min_neighbors must be positive.")
    end
    if target_neighbors <= 0
        error("target_neighbors must be positive.")
    end
    if max_retries <= 0
        error("max_retries must be positive.")
    end
    if full_fallback_max_edges < 0
        error("full_fallback_max_edges must be non-negative.")
    end
    if !(uniform_mode in (:hard, :soft))
        error("uniform_mode must be :hard or :soft.")
    end
    if uniform_penalty < 0
        error("uniform_penalty must be non-negative.")
    end
    if uniform_rel_tol < 0
        error("uniform_rel_tol must be non-negative.")
    end
    if retry_factor <= 1.0 && max_retries > 1
        error("retry_factor must be greater than 1.0 when max_retries > 1.")
    end

    total_pop = sum(pop_clean.population)
    target_pop_per_cell = total_pop / N
    max_neighbors_eff = isnothing(max_neighbors) ? N : min(max_neighbors, N)
    min_neighbors_eff = min(min_neighbors, max_neighbors_eff)
    target_neighbors_eff = min(target_neighbors, M)
    required_neighbors = ceil.(Int, pop_clean.population ./ target_pop_per_cell)

    lat_min, lat_max = minimum(pop_clean.y), maximum(pop_clean.y)
    lon_min, lon_max = minimum(pop_clean.x), maximum(pop_clean.x)
    x_min, max_x = minimum(cartogram.x), maximum(cartogram.x)
    y_min, max_y = minimum(cartogram.y), maximum(cartogram.y)

    lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
    lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
    x_span = (max_x - x_min) > 0 ? (max_x - x_min) : 1.0
    y_span = (max_y - y_min) > 0 ? (max_y - y_min) : 1.0

    pop_norm_x = (pop_clean.x .- lon_min) ./ lon_span
    pop_norm_y = (pop_clean.y .- lat_min) ./ lat_span
    pop_carto_x = x_min .+ pop_norm_x .* x_span
    pop_carto_y = y_min .+ pop_norm_y .* y_span

    unique_carto_x = sort(unique(cartogram.x))
    unique_carto_y = sort(unique(cartogram.y))
    carto_step_x = length(unique_carto_x) > 1 ? minimum(diff(unique_carto_x)) : 1.0
    carto_step_y = length(unique_carto_y) > 1 ? minimum(diff(unique_carto_y)) : 1.0

    last_status = nothing
    last_edge_count = 0
    last_target_error = Inf

    for attempt in 1:max_retries
        attempt_oversample = oversample * retry_factor^(attempt - 1)
        attempt_target_neighbors = min(M, ceil(Int, target_neighbors_eff * retry_factor^(attempt - 1)))
        edge_set = Set{Tuple{Int, Int}}()

        for i in 1:M
            required = required_neighbors[i]
            feasible_cap = min(max(max_neighbors_eff, required), N)
            K = clamp(ceil(Int, attempt_oversample * required), min_neighbors_eff, feasible_cap)

            dists = Vector{Float64}(undef, N)
            px, py = pop_carto_x[i], pop_carto_y[i]
            for j in 1:N
                dx = (px - cartogram.x[j]) / carto_step_x
                dy = (py - cartogram.y[j]) / carto_step_y
                dists[j] = sqrt(dx^2 + dy^2)
            end

            for j in partialsortperm(dists, 1:K)
                push!(edge_set, (i, j))
            end
        end

        for j in 1:N
            dists = Vector{Float64}(undef, M)
            cx, cy = cartogram.x[j], cartogram.y[j]
            for i in 1:M
                dx = (pop_carto_x[i] - cx) / carto_step_x
                dy = (pop_carto_y[i] - cy) / carto_step_y
                dists[i] = sqrt(dx^2 + dy^2)
            end

            for i in partialsortperm(dists, 1:attempt_target_neighbors)
                push!(edge_set, (i, j))
            end
        end

        covered_targets = falses(N)
        for (_, j) in edge_set
            covered_targets[j] = true
        end

        # Exact column constraints are immediately infeasible if a target has no
        # incoming edge, so add the nearest source edge for uncovered targets.
        for j in findall(!, covered_targets)
            best_i = 1
            best_dist = Inf
            cx, cy = cartogram.x[j], cartogram.y[j]
            for i in 1:M
                dx = (pop_carto_x[i] - cx) / carto_step_x
                dy = (pop_carto_y[i] - cy) / carto_step_y
                dist = sqrt(dx^2 + dy^2)
                if dist < best_dist
                    best_dist = dist
                    best_i = i
                end
            end
            push!(edge_set, (best_i, j))
        end

        # Local nearest-neighbor graphs can still be infeasible even when every
        # source has enough neighbors and every target is covered. On the last
        # retry, fall back to the full graph for modest country-sized problems.
        if attempt == max_retries && M * N <= full_fallback_max_edges
            for i in 1:M, j in 1:N
                push!(edge_set, (i, j))
            end
        end

        valid_pairs = collect(edge_set)
        sort!(valid_pairs)
        total_pairs = length(valid_pairs)
        last_edge_count = total_pairs

        distances = Vector{Float64}(undef, total_pairs)
        source_to_indices = [Int[] for _ in 1:M]
        target_to_indices = [Int[] for _ in 1:N]

        for (idx, (i, j)) in enumerate(valid_pairs)
            dx = (pop_carto_x[i] - cartogram.x[j]) / carto_step_x
            dy = (pop_carto_y[i] - cartogram.y[j]) / carto_step_y
            distances[idx] = sqrt(dx^2 + dy^2)
            push!(source_to_indices[i], idx)
            push!(target_to_indices[j], idx)
        end

        model = Model(HiGHS.Optimizer)
        if silent
            set_silent(model)
        end
        set_attribute(model, "solver", uniform_mode == :soft ? "simplex" : "ipm")
        set_attribute(model, "threads", Threads.nthreads())

        @variable(model, w[1:total_pairs] >= 0)
        if uniform_mode == :soft
            @variable(model, deficit[1:N] >= 0)
            @variable(model, surplus[1:N] >= 0)
            @objective(model, Min,
                sum(w[idx] * distances[idx] for idx in 1:total_pairs) +
                uniform_penalty * sum(deficit[j] + surplus[j] for j in 1:N)
            )
        else
            @objective(model, Min, sum(w[idx] * distances[idx] for idx in 1:total_pairs))
        end

        for i in 1:M
            indices = source_to_indices[i]
            @constraint(model, sum(w[idx] for idx in indices) == pop_clean.population[i])
        end

        for j in 1:N
            indices = target_to_indices[j]
            if uniform_mode == :soft
                @constraint(model, sum(w[idx] for idx in indices) + deficit[j] - surplus[j] == target_pop_per_cell)
            else
                @constraint(model, sum(w[idx] for idx in indices) == target_pop_per_cell)
            end
        end

        optimize!(model)
        last_status = termination_status(model)

        if last_status != OPTIMAL
            continue
        end

        w_vals = value.(w)
        target_loads = zeros(Float64, N)
        for idx in 1:total_pairs
            _, j = valid_pairs[idx]
            target_loads[j] += w_vals[idx]
        end

        max_target_error = maximum(abs.(target_loads .- target_pop_per_cell))
        last_target_error = max_target_error
        if uniform_mode == :soft && max_target_error > uniform_rel_tol * target_pop_per_cell
            continue
        end

        assigned_h3 = Vector{eltype(pop_clean.h3)}()
        assigned_x = Vector{eltype(cartogram.x)}()
        assigned_y = Vector{eltype(cartogram.y)}()
        assigned_weight = Vector{Float64}()
        assigned_overlap = Vector{Float64}()

        sizehint!(assigned_h3, total_pairs)
        sizehint!(assigned_x, total_pairs)
        sizehint!(assigned_y, total_pairs)
        sizehint!(assigned_weight, total_pairs)
        sizehint!(assigned_overlap, total_pairs)

        for idx in 1:total_pairs
            overlap = w_vals[idx]
            if overlap > threshold
                i, j = valid_pairs[idx]
                h3_pop = pop_clean.population[i]
                weight = h3_pop > 0 ? (overlap / h3_pop) : 0.0

                push!(assigned_h3, pop_clean.h3[i])
                push!(assigned_x, cartogram.x[j])
                push!(assigned_y, cartogram.y[j])
                push!(assigned_weight, weight)
                push!(assigned_overlap, overlap)
            end
        end

        return DataFrame(
            h3 = assigned_h3,
            x = assigned_x,
            y = assigned_y,
            weight = assigned_weight,
            overlap = assigned_overlap
        )
    end

    max_required = maximum(required_neighbors)
    error("Adaptive OT failed to find an acceptable solution after $max_retries attempts. Last status: $last_status. Last edge count: $last_edge_count. Max required neighbors from source/target mass ratio: $max_required. Uniform mode: $uniform_mode. Last max target load error: $last_target_error.")
end
