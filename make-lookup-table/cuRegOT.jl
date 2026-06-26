using CUDA, SparseArrays, LinearAlgebra
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
        max_val = -Inf
        for j in 1:m
            val = beta[j] - M[i, j]
            if val > max_val
                max_val = val
            end
        end
        
        sum_exp = 0.0
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
        max_val = -Inf
        for i in 1:n
            val = alpha[i] - M[i, j]
            if val > max_val
                max_val = val
            end
        end
        
        sum_exp = 0.0
        for i in 1:n
            sum_exp += exp((alpha[i] - M[i, j] - max_val) / eta)
        end
        
        beta[j] = eta * log(b[j]) - max_val - eta * log(sum_exp)
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
