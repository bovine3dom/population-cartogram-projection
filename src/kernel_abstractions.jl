@kernel function _ka_sinkhorn_row_kernel!(
    transposed_cost,
    alpha,
    beta,
    eta,
    source_mass,
    target_count,
)
    source_index = @index(Group, Linear)
    thread_index = @index(Local, Linear)
    max_shared = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    sum_shared = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)

    row_max = -Inf32
    target_index = thread_index
    while target_index <= target_count
        row_max = max(row_max, beta[target_index] - transposed_cost[target_index, source_index])
        target_index += SINKHORN_WORKGROUP_SIZE
    end
    max_shared[thread_index] = row_max
    @synchronize

    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        if thread_index <= offset
            max_shared[thread_index] = max(max_shared[thread_index], max_shared[thread_index + offset])
        end
        @synchronize
    end

    row_sum = 0.0f0
    target_index = thread_index
    while target_index <= target_count
        row_sum += exp(
            (beta[target_index] - transposed_cost[target_index, source_index] - max_shared[1]) / eta,
        )
        target_index += SINKHORN_WORKGROUP_SIZE
    end
    sum_shared[thread_index] = row_sum
    @synchronize

    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        if thread_index <= offset
            sum_shared[thread_index] += sum_shared[thread_index + offset]
        end
        @synchronize
    end

    if thread_index == 1
        alpha[source_index] =
            eta * log(source_mass[source_index]) - max_shared[1] - eta * log(sum_shared[1])
    end
end

@kernel function _ka_sinkhorn_column_kernel!(
    cost,
    alpha,
    beta,
    eta,
    target_mass,
    source_count,
)
    target_index = @index(Group, Linear)
    thread_index = @index(Local, Linear)
    max_shared = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    sum_shared = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)

    column_max = -Inf32
    source_index = thread_index
    while source_index <= source_count
        column_max = max(column_max, alpha[source_index] - cost[source_index, target_index])
        source_index += SINKHORN_WORKGROUP_SIZE
    end
    max_shared[thread_index] = column_max
    @synchronize

    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        if thread_index <= offset
            max_shared[thread_index] = max(max_shared[thread_index], max_shared[thread_index + offset])
        end
        @synchronize
    end

    column_sum = 0.0f0
    source_index = thread_index
    while source_index <= source_count
        column_sum += exp(
            (alpha[source_index] - cost[source_index, target_index] - max_shared[1]) / eta,
        )
        source_index += SINKHORN_WORKGROUP_SIZE
    end
    sum_shared[thread_index] = column_sum
    @synchronize

    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        if thread_index <= offset
            sum_shared[thread_index] += sum_shared[thread_index + offset]
        end
        @synchronize
    end

    if thread_index == 1
        beta[target_index] =
            eta * log(target_mass[target_index]) - max_shared[1] - eta * log(sum_shared[1])
    end
end

@kernel function _ka_row_marginal_kernel!(
    transposed_cost,
    alpha,
    beta,
    eta,
    row_sums,
    target_count,
)
    source_index = @index(Group, Linear)
    thread_index = @index(Local, Linear)
    shared = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)

    row_sum = 0.0f0
    target_index = thread_index
    while target_index <= target_count
        row_sum += exp(
            (alpha[source_index] + beta[target_index] - transposed_cost[target_index, source_index]) / eta,
        )
        target_index += SINKHORN_WORKGROUP_SIZE
    end
    shared[thread_index] = row_sum
    @synchronize

    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        if thread_index <= offset
            shared[thread_index] += shared[thread_index + offset]
        end
        @synchronize
    end
    thread_index == 1 && (row_sums[source_index] = shared[1])
end

@kernel function _ka_column_marginal_kernel!(
    cost,
    alpha,
    beta,
    eta,
    column_sums,
    source_count,
)
    target_index = @index(Group, Linear)
    thread_index = @index(Local, Linear)
    shared = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)

    column_sum = 0.0f0
    source_index = thread_index
    while source_index <= source_count
        column_sum += exp(
            (alpha[source_index] + beta[target_index] - cost[source_index, target_index]) / eta,
        )
        source_index += SINKHORN_WORKGROUP_SIZE
    end
    shared[thread_index] = column_sum
    @synchronize

    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        if thread_index <= offset
            shared[thread_index] += shared[thread_index + offset]
        end
        @synchronize
    end
    thread_index == 1 && (column_sums[target_index] = shared[1])
end

function _ka_backend(name::Symbol)
    backend = if name === :cuda
        CUDA.CUDABackend()
    elseif name === :oneapi
        oneAPI.oneAPIBackend()
    elseif name === :cpu
        KA.CPU()
    else
        throw(ArgumentError("KernelAbstractions backend must be :cuda, :oneapi, or :cpu"))
    end
    KA.functional(backend) || throw(ArgumentError("KernelAbstractions $name backend is not functional"))
    return backend
end

function _ka_copy_async(backend, source)
    destination = KA.allocate(backend, eltype(source), size(source))
    KA.copyto!(backend, destination, source)
    return destination
end

_ka_copy_async(::KA.CPU, source) = source

function _ka_marginal_error!(
    backend,
    row_kernel,
    column_kernel,
    row_sums,
    column_sums,
    alpha,
    beta,
    cost,
    transposed_cost,
    source_mass,
    target_mass,
    eta,
)
    source_count, target_count = size(cost)
    row_kernel(
        transposed_cost,
        alpha,
        beta,
        eta,
        row_sums,
        target_count;
        ndrange=source_count * SINKHORN_WORKGROUP_SIZE,
    )
    column_kernel(
        cost,
        alpha,
        beta,
        eta,
        column_sums,
        source_count;
        ndrange=target_count * SINKHORN_WORKGROUP_SIZE,
    )
    absolute_error = sum(abs.(row_sums .- source_mass)) +
                     sum(abs.(column_sums .- target_mass))
    return Float64(absolute_error / sum(source_mass))
end

function solve_sinkhorn_ka(
    cost,
    source_mass,
    target_mass;
    backend::Symbol=:oneapi,
    eta_schedule=Float32[0.05, 0.02, 0.01, 0.005],
    max_iters_per_eta::Int=1_000,
    tol::Real=1e-5,
    check_every::Int=25,
)
    problem = _prepare_sinkhorn_inputs(
        cost,
        source_mass,
        target_mass,
        eta_schedule,
        max_iters_per_eta,
        tol,
        check_every,
    )
    ka_backend = _ka_backend(backend)
    (; float_cost, float_source_mass, float_target_mass, float_eta_schedule) = problem
    source_count, target_count = size(float_cost)

    transposed_float_cost = Matrix(transpose(float_cost))
    cost_device = nothing
    transposed_cost_device = nothing
    source_mass_device = nothing
    target_mass_device = nothing
    GC.@preserve float_cost transposed_float_cost float_source_mass float_target_mass begin
        cost_device = _ka_copy_async(ka_backend, float_cost)
        transposed_cost_device = _ka_copy_async(ka_backend, transposed_float_cost)
        source_mass_device = _ka_copy_async(ka_backend, float_source_mass)
        target_mass_device = _ka_copy_async(ka_backend, float_target_mass)
        KA.synchronize(ka_backend)
    end
    alpha_device = KA.zeros(ka_backend, Float32, source_count)
    beta_device = KA.zeros(ka_backend, Float32, target_count)
    row_sums_device = KA.allocate(ka_backend, Float32, source_count)
    column_sums_device = KA.allocate(ka_backend, Float32, target_count)

    row_update! = _ka_sinkhorn_row_kernel!(ka_backend, SINKHORN_WORKGROUP_SIZE)
    column_update! = _ka_sinkhorn_column_kernel!(ka_backend, SINKHORN_WORKGROUP_SIZE)
    row_marginal! = _ka_row_marginal_kernel!(ka_backend, SINKHORN_WORKGROUP_SIZE)
    column_marginal! = _ka_column_marginal_kernel!(ka_backend, SINKHORN_WORKGROUP_SIZE)

    function step!(eta)
        row_update!(
            transposed_cost_device,
            alpha_device,
            beta_device,
            eta,
            source_mass_device,
            target_count;
            ndrange=source_count * SINKHORN_WORKGROUP_SIZE,
        )
        column_update!(
            cost_device,
            alpha_device,
            beta_device,
            eta,
            target_mass_device,
            source_count;
            ndrange=target_count * SINKHORN_WORKGROUP_SIZE,
        )
    end
    marginal_error!(eta) = _ka_marginal_error!(
        ka_backend,
        row_marginal!,
        column_marginal!,
        row_sums_device,
        column_sums_device,
        alpha_device,
        beta_device,
        cost_device,
        transposed_cost_device,
        source_mass_device,
        target_mass_device,
        eta,
    )
    state = _run_sinkhorn(
        step!,
        marginal_error!,
        float_eta_schedule,
        max_iters_per_eta,
        tol,
        check_every,
    )
    return _sinkhorn_result(
        Array(alpha_device),
        Array(beta_device),
        float_eta_schedule,
        state,
    )
end
