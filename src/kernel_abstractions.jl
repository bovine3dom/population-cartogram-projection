@kernel function _sinkhorn_row!(transposed_cost, alpha, beta, eta, source_mass, targets)
    source = @index(Group, Linear)
    thread = @index(Local, Linear)
    maxima = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    totals = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)

    maximum_value = -Inf32
    target = thread
    while target <= targets
        maximum_value = max(maximum_value, beta[target] - transposed_cost[target, source])
        target += SINKHORN_WORKGROUP_SIZE
    end
    maxima[thread] = maximum_value
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (maxima[thread] = max(maxima[thread], maxima[thread + offset]))
        @synchronize
    end

    total = 0.0f0
    target = thread
    while target <= targets
        total += exp((beta[target] - transposed_cost[target, source] - maxima[1]) / eta)
        target += SINKHORN_WORKGROUP_SIZE
    end
    totals[thread] = total
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (totals[thread] += totals[thread + offset])
        @synchronize
    end
    thread == 1 && (alpha[source] =
        eta * log(source_mass[source]) - maxima[1] - eta * log(totals[1]))
end

@kernel function _sinkhorn_column!(cost, alpha, beta, eta, target_mass, sources)
    target = @index(Group, Linear)
    thread = @index(Local, Linear)
    maxima = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    totals = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)

    maximum_value = -Inf32
    source = thread
    while source <= sources
        maximum_value = max(maximum_value, alpha[source] - cost[source, target])
        source += SINKHORN_WORKGROUP_SIZE
    end
    maxima[thread] = maximum_value
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (maxima[thread] = max(maxima[thread], maxima[thread + offset]))
        @synchronize
    end

    total = 0.0f0
    source = thread
    while source <= sources
        total += exp((alpha[source] - cost[source, target] - maxima[1]) / eta)
        source += SINKHORN_WORKGROUP_SIZE
    end
    totals[thread] = total
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (totals[thread] += totals[thread + offset])
        @synchronize
    end
    thread == 1 && (beta[target] =
        eta * log(target_mass[target]) - maxima[1] - eta * log(totals[1]))
end

@kernel function _row_marginals!(transposed_cost, alpha, beta, eta, output, targets)
    source = @index(Group, Linear)
    thread = @index(Local, Linear)
    maxima = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    totals = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    maximum_value = -Inf32
    target = thread
    while target <= targets
        maximum_value = max(
            maximum_value,
            (alpha[source] + beta[target] - transposed_cost[target, source]) / eta,
        )
        target += SINKHORN_WORKGROUP_SIZE
    end
    maxima[thread] = maximum_value
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (maxima[thread] = max(maxima[thread], maxima[thread + offset]))
        @synchronize
    end

    total = 0.0f0
    target = thread
    while target <= targets
        total += exp(
            (alpha[source] + beta[target] - transposed_cost[target, source]) / eta - maxima[1],
        )
        target += SINKHORN_WORKGROUP_SIZE
    end
    totals[thread] = total
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (totals[thread] += totals[thread + offset])
        @synchronize
    end
    thread == 1 && (output[source] = maxima[1] + log(totals[1]))
end

@kernel function _column_marginals!(cost, alpha, beta, eta, output, sources)
    target = @index(Group, Linear)
    thread = @index(Local, Linear)
    maxima = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    totals = @localmem Float32 (SINKHORN_WORKGROUP_SIZE,)
    maximum_value = -Inf32
    source = thread
    while source <= sources
        maximum_value = max(
            maximum_value,
            (alpha[source] + beta[target] - cost[source, target]) / eta,
        )
        source += SINKHORN_WORKGROUP_SIZE
    end
    maxima[thread] = maximum_value
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (maxima[thread] = max(maxima[thread], maxima[thread + offset]))
        @synchronize
    end

    total = 0.0f0
    source = thread
    while source <= sources
        total += exp(
            (alpha[source] + beta[target] - cost[source, target]) / eta - maxima[1],
        )
        source += SINKHORN_WORKGROUP_SIZE
    end
    totals[thread] = total
    @synchronize
    for offset in (128, 64, 32, 16, 8, 4, 2, 1)
        thread <= offset && (totals[thread] += totals[thread + offset])
        @synchronize
    end
    thread == 1 && (output[target] = maxima[1] + log(totals[1]))
end

function _copy_to_backend(backend, source)
    destination = KA.allocate(backend, eltype(source), size(source))
    GC.@preserve source begin
        KA.copyto!(backend, destination, source)
        KA.synchronize(backend)
    end
    return destination
end

function _copy_to_host!(backend, destination, source)
    GC.@preserve destination begin
        KA.copyto!(backend, destination, source)
        KA.synchronize(backend)
    end
    return destination
end

function _snapshot(backend, beta, eta, converged)
    host_beta = _copy_to_host!(backend, Vector{Float32}(undef, length(beta)), beta)
    all(isfinite, host_beta) ||
        error("non-finite Sinkhorn dual potential")
    return SinkhornResult(host_beta, eta, converged)
end

function _marginal_error(log_marginals, expected)
    total = 0.0
    maximum_log = log(floatmax(Float64))
    for index in eachindex(expected)
        log_value = Float64(log_marginals[index])
        value = log_value == -Inf ? 0.0 : log_value > maximum_log ? Inf : exp(log_value)
        total += abs(value - Float64(expected[index]))
    end
    return total
end

function _solve_sinkhorn(
    cost,
    source_mass,
    target_mass,
    backend;
    eta_schedule,
    observed_etas,
    observer,
    max_iters_per_eta,
    tol,
    check_every,
)
    max_iters_per_eta isa Integer && !(max_iters_per_eta isa Bool) && max_iters_per_eta > 0 ||
        throw(ArgumentError("max_iters_per_eta must be a positive integer"))
    check_every isa Integer && !(check_every isa Bool) && check_every > 0 ||
        throw(ArgumentError("check_every must be a positive integer"))
    !(tol isa Bool) && isfinite(tol) && 10eps(Float32) <= tol < 1 ||
        throw(ArgumentError("tol must be finite and in [$(10eps(Float32)), 1)"))

    sources, targets = size(cost)
    transposed_cost = Matrix(transpose(cost))
    cost_device = _copy_to_backend(backend, cost)
    transposed_device = _copy_to_backend(backend, transposed_cost)
    source_mass_device = _copy_to_backend(backend, source_mass)
    target_mass_device = _copy_to_backend(backend, target_mass)
    alpha = KA.zeros(backend, Float32, sources)
    beta = KA.zeros(backend, Float32, targets)
    row_sums = KA.allocate(backend, Float32, sources)
    column_sums = KA.allocate(backend, Float32, targets)
    host_rows = Vector{Float32}(undef, sources)
    host_columns = Vector{Float32}(undef, targets)

    row_update! = _sinkhorn_row!(backend, SINKHORN_WORKGROUP_SIZE)
    column_update! = _sinkhorn_column!(backend, SINKHORN_WORKGROUP_SIZE)
    row_marginals! = _row_marginals!(backend, SINKHORN_WORKGROUP_SIZE)
    column_marginals! = _column_marginals!(backend, SINKHORN_WORKGROUP_SIZE)
    for eta in eta_schedule
        converged = false
        marginal_error = Inf
        for iteration in 1:max_iters_per_eta
            row_update!(
                transposed_device, alpha, beta, eta, source_mass_device, targets;
                ndrange=sources * SINKHORN_WORKGROUP_SIZE,
            )
            column_update!(
                cost_device, alpha, beta, eta, target_mass_device, sources;
                ndrange=targets * SINKHORN_WORKGROUP_SIZE,
            )
            if iteration == 1 || iteration % check_every == 0 || iteration == max_iters_per_eta
                row_marginals!(
                    transposed_device, alpha, beta, eta, row_sums, targets;
                    ndrange=sources * SINKHORN_WORKGROUP_SIZE,
                )
                column_marginals!(
                    cost_device, alpha, beta, eta, column_sums, sources;
                    ndrange=targets * SINKHORN_WORKGROUP_SIZE,
                )
                _copy_to_host!(backend, host_rows, row_sums)
                _copy_to_host!(backend, host_columns, column_sums)
                marginal_error = (
                    _marginal_error(host_rows, source_mass) +
                    _marginal_error(host_columns, target_mass)
                ) / sum(source_mass)
                isnan(marginal_error) && error(
                    "non-finite Sinkhorn marginal error at eta=$eta iteration=$iteration",
                )
                if marginal_error <= tol
                    converged = true
                    break
                end
            end
        end
        if eta in observed_etas
            observer(_snapshot(backend, beta, eta, converged)) && return nothing
        end
    end
    return nothing
end
