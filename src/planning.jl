function _dense_memory_estimate(source_count, target_count)
    entries = Base.checked_mul(source_count, target_count)
    matrix_bytes = Base.checked_mul(entries, sizeof(Float32))
    vectors = Base.checked_add(source_count, target_count)
    host_dense_bytes = Base.checked_add(Base.checked_mul(2, matrix_bytes), Base.checked_mul(4, vectors))
    backend_dense_bytes = Base.checked_add(Base.checked_mul(2, matrix_bytes), Base.checked_mul(12, vectors))
    return (;
        cost_entries=entries,
        matrix_bytes,
        host_dense_bytes,
        backend_dense_bytes,
        combined_dense_bytes=Base.checked_add(host_dense_bytes, backend_dense_bytes),
    )
end

function _budget_factor(source_count, native_targets, budget, memory_field)
    budget = _positive_int(budget, "memory budget in bytes")
    base = _dense_memory_estimate(source_count, native_targets)
    getproperty(base, memory_field) <= budget || throw(ArgumentError(
        "factor 1 requires $(getproperty(base, memory_field)) bytes, exceeding the $budget-byte budget",
    ))
    vector_bytes = memory_field === :host_dense_bytes ? 4 : 12
    coefficient = Base.checked_add(Base.checked_mul(8, source_count), vector_bytes)
    constant_bytes = Base.checked_mul(vector_bytes, source_count)
    denominator = Base.checked_mul(native_targets, coefficient)
    squared_limit = fld(budget - constant_bytes, denominator)
    return max(1, isqrt(squared_limit))
end

"""
    plan_mapping(sources, [grid]; factor, target_cells, sources_per_target,
                 max_host_bytes, max_backend_bytes)

Select an explicit uniform target subdivision and estimate dense host and
accelerator storage before fitting. Supply at most one subdivision request, or
one or both memory budgets. With no request, factor 1 is used. Returned memory
figures are estimates rather than guaranteed process peaks.
"""
function plan_mapping(
    sources::AbstractDataFrame,
    grid::AbstractDataFrame=load_owid_grid();
    factor=nothing,
    target_cells=nothing,
    sources_per_target=nothing,
    max_host_bytes=nothing,
    max_backend_bytes=nothing,
)
    native_grid = _country_targets(sources, grid)
    explicit = count(!isnothing, (factor, target_cells, sources_per_target))
    has_budget = !isnothing(max_host_bytes) || !isnothing(max_backend_bytes)
    explicit + has_budget <= 1 || throw(ArgumentError(
        "supply one of factor, target_cells, sources_per_target, or memory budgets",
    ))

    selection = :identity
    requested = nothing
    planned_grid = nothing
    if !isnothing(factor)
        planned_grid = subdivide_grid(native_grid; factor)
        selection = :factor
        requested = factor
    elseif !isnothing(target_cells)
        planned_grid = subdivide_grid(native_grid; target_cells)
        selection = :target_cells
        requested = target_cells
    elseif !isnothing(sources_per_target)
        !(sources_per_target isa Bool) && sources_per_target isa Real &&
            isfinite(sources_per_target) && sources_per_target > 0 || throw(ArgumentError(
                "sources_per_target must be finite and positive",
            ))
        ideal_factor = sqrt(nrow(sources) / (nrow(native_grid) * sources_per_target))
        maximum_factor = isqrt(fld(typemax(Int), nrow(native_grid)))
        isfinite(ideal_factor) && ideal_factor <= maximum_factor || throw(ArgumentError(
            "sources_per_target requires an unrepresentable subdivision factor",
        ))
        candidates = unique(max.(1, [floor(Int, ideal_factor), ceil(Int, ideal_factor)]))
        filter!(<=(maximum_factor), candidates)
        selected_factor = first(sort!(candidates; by=candidate -> (
            abs(nrow(sources) / (nrow(native_grid) * candidate^2) - sources_per_target),
            candidate,
        )))
        planned_grid = subdivide_grid(native_grid; factor=selected_factor)
        selection = :sources_per_target
        requested = Float64(sources_per_target)
    elseif has_budget
        factors = Int[]
        !isnothing(max_host_bytes) && push!(
            factors,
            _budget_factor(nrow(sources), nrow(native_grid), max_host_bytes, :host_dense_bytes),
        )
        !isnothing(max_backend_bytes) && push!(
            factors,
            _budget_factor(nrow(sources), nrow(native_grid), max_backend_bytes, :backend_dense_bytes),
        )
        selected_factor = minimum(factors)
        planned_grid = subdivide_grid(native_grid; factor=selected_factor)
        selection = :memory_budget
        requested = (host=max_host_bytes, backend=max_backend_bytes)
    else
        planned_grid = subdivide_grid(native_grid; factor=1)
    end

    selected_factor = isqrt(div(nrow(planned_grid), nrow(native_grid)))
    memory = _dense_memory_estimate(nrow(sources), nrow(planned_grid))
    metadata = merge(memory, (;
        schema_version=1,
        sources=nrow(sources),
        native_targets=nrow(native_grid),
        subdivision_factor=selected_factor,
        targets=nrow(planned_grid),
        sources_per_target=nrow(sources) / nrow(planned_grid),
        selection,
        requested,
    ))
    return MappingPlan(planned_grid, metadata)
end
