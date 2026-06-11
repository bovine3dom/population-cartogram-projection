using CUDA, SparseArrays, LinearAlgebra
# gemini 3.5 flash vomit draft implementation of https://arxiv.org/abs/2605.08793

# ==============================================================================
# 1. FUSED CUDA KERNELS FOR GRADIENT EVALUATION & SINKHORN ITERATIONS
# ==============================================================================

"""
Fused CUDA kernel for evaluating the row sums and column sums of the 
transport plan matrix: T_ij = exp((alpha_i + beta_j - M_ij) / eta)
Uses warp shuffles for row reductions and shared memory for column reductions.
"""
function fused_grad_kernel!(M, alpha, beta, eta, row_sums, col_sums, n, m)
    tx = threadIdx().x  # 1 to 32 (warp width)
    ty = threadIdx().y  # 1 to D (typically 8)
    bx = blockIdx().x
    by = blockIdx().y
    
    FT = eltype(M)
    
    # Dynamic shared memory allocation for column reduction
    shared_cols = CUDA.CuDynamicSharedArray(FT, (32, blockDim().y))
    
    # Direct index mapping
    i = (by - 1) * blockDim().y + ty
    j = (bx - 1) * blockDim().x + tx
    
    T_ij = zero(FT)
    if i <= n && j <= m
        T_ij = exp((alpha[i] + beta[j] - M[i, j]) / eta)
    end
    
    # --- Warp-level Row Reduction (Summing across columns j for row i) ---
    val = T_ij
    mask = 0xffffffff
    for offset in (16, 8, 4, 2, 1)
        val += CUDA.shfl_down_sync(mask, val, offset)
    end
    
    # Thread 1 of each warp writes partial sum to global memory row_sums
    if tx == 1 && i <= n
        CUDA.@atomic row_sums[i] += val
    end
    
    # --- Shared Memory Column Reduction (Summing across rows i for column j) ---
    shared_cols[tx, ty] = T_ij
    CUDA.sync_threads()
    
    # Thread 1 of each block column sums values in shared memory
    if ty == 1 && j <= m
        sum_col_block = zero(FT)
        for k in 1:blockDim().y
            sum_col_block += shared_cols[tx, k]
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
