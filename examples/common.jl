using CSV
using DataFrames
import KernelAbstractions as KA

const EXAMPLE_ROOT = normpath(joinpath(@__DIR__, ".."))
const CARTOGRAM_PATH = joinpath(EXAMPLE_ROOT, "data", "cartogram.csv")

function backend_from_name(name::AbstractString)
    normalized = lowercase(name)
    if normalized == "cpu"
        return KA.CPU()
    elseif normalized == "cuda"
        @eval import CUDA
        return Core.eval(@__MODULE__, :(CUDA.CUDABackend()))
    elseif normalized == "amdgpu"
        @eval import AMDGPU
        return Core.eval(@__MODULE__, :(AMDGPU.ROCBackend()))
    elseif normalized == "metal"
        @eval import Metal
        return Core.eval(@__MODULE__, :(Metal.MetalBackend()))
    elseif normalized == "oneapi"
        @eval import oneAPI
        return Core.eval(@__MODULE__, :(oneAPI.oneAPIBackend()))
    end
    throw(ArgumentError("backend must be cpu, cuda, amdgpu, metal, or oneapi"))
end

function _cartogram_step(values)
    sorted = sort!(unique(Float64.(values)))
    return length(sorted) > 1 ? minimum(diff(sorted)) : 1.0
end

function load_cartogram(country::Integer; factor::Integer=1, path=CARTOGRAM_PATH)
    factor > 0 || throw(ArgumentError("factor must be positive"))
    raw = CSV.read(
        path,
        DataFrame;
        header=[:x, :y, :country],
        types=Dict(:x => Int, :y => Int, :country => Int),
    )
    filter!(:country => ==(country), raw)
    nrow(raw) > 0 || error("cartogram has no cells for country $country")
    raw.cell_id = ["$(lpad(string(country), 3, '0')):$x:$y" for (x, y) in zip(raw.x, raw.y)]
    raw.parent_cell_id = copy(raw.cell_id)
    factor == 1 && return select(raw, :x, :y, :cell_id, :parent_cell_id)

    step_x = _cartogram_step(raw.x)
    step_y = _cartogram_step(raw.y)
    rows = NamedTuple[]
    for parent in eachrow(raw), i in 1:factor, j in 1:factor
        push!(rows, (
            x=factor * parent.x + (2i - factor - 1) * step_x / 2,
            y=factor * parent.y + (2j - factor - 1) * step_y / 2,
            cell_id="$(parent.cell_id):sub$factor:$i:$j",
            parent_cell_id=parent.cell_id,
        ))
    end
    result = DataFrame(rows)
    result.x = all(isinteger, result.x) ? round.(Int, result.x) : result.x
    result.y = all(isinteger, result.y) ? round.(Int, result.y) : result.y
    return result
end

function transported_rows(mapping, sources)
    rows = leftjoin(mapping, select(sources, :id, :value); on=:id, validate=(false, true))
    any(ismissing, rows.value) && error("mapping contains unknown source ids")
    rows.transported_value = rows.weight .* rows.value
    return rows
end

function projected_values(mapping, sources, cartogram)
    transported = transported_rows(mapping, sources)
    totals = combine(
        groupby(transported, [:x, :y]; sort=false),
        :transported_value => sum => :value,
    )
    result = leftjoin(select(cartogram, :x, :y, :cell_id, :parent_cell_id), totals; on=[:x, :y])
    result.value = coalesce.(result.value, 0.0)
    return result
end

function retained_value_share(mapping, sources)
    return sum(transported_rows(mapping, sources).transported_value) /
           sum(Float64.(sources.value))
end
