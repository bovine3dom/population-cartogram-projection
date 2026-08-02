module PopulationCartogramProjection

using DataFrames
import KernelAbstractions as KA
using KernelAbstractions: @index, @kernel, @localmem, @private, @synchronize

export distribute

const CARTOGRAM_COLUMNS = (:x, :y)
const SOURCE_COLUMNS = (:x, :y, :value, :id)
const MATRIX_FREE_REDUCTION_LANES = 32
const MATRIX_FREE_OUTPUTS_PER_GROUP = 8
const MATRIX_FREE_MAX_PAIRS_PER_LAUNCH = 200_000_000

struct SinkhornResult
    beta::Vector{Float32}
    eta::Float32
    converged::Bool
end

function _require_columns(table, required, label)
    available = Set(Symbol.(names(table)))
    missing_columns = filter(column -> column ∉ available, required)
    isempty(missing_columns) || throw(ArgumentError(
        "$label is missing required column(s): $(join(string.(missing_columns), ", "))",
    ))
end

function _finite_coordinate(value)
    return value isa Real && !(value isa Bool) && isfinite(value) &&
           isfinite(Float64(value))
end

_coordinate_value(value) = iszero(value) ? 0.0 : Float64(value)

function _validate_inputs(cartogram, sources)
    _require_columns(cartogram, CARTOGRAM_COLUMNS, "cartogram")
    _require_columns(sources, SOURCE_COLUMNS, "source table")
    nrow(cartogram) > 0 || throw(ArgumentError("cartogram is empty"))
    nrow(sources) > 0 || throw(ArgumentError("source table is empty"))

    for column in (:x, :y)
        all(_finite_coordinate, cartogram[!, column]) ||
            throw(ArgumentError("cartogram $column must contain finite numbers"))
        all(_finite_coordinate, sources[!, column]) ||
            throw(ArgumentError("source $column must contain finite numbers"))
    end
    allunique(zip(cartogram.x, cartogram.y)) ||
        throw(ArgumentError("cartogram (x, y) coordinates must be unique"))
    allunique(zip(_coordinate_value.(cartogram.x), _coordinate_value.(cartogram.y))) || throw(ArgumentError(
        "cartogram coordinates must remain unique when represented as Float64",
    ))
    any(ismissing, sources.id) && throw(ArgumentError("source id cannot be missing"))
    allunique(sources.id) || throw(ArgumentError("source id must be unique"))
    all(value -> _finite_coordinate(value) && value > 0, sources.value) || throw(
        ArgumentError("source value must contain finite positive Float64 values"),
    )
    return nothing
end

include("spatial.jl")
include("kernel_abstractions.jl")
include("truncation.jl")
include("automatic_eta.jl")

"""
    distribute(cartogram, sources; backend)

Distribute one country's positive source values over a balanced cartogram.
`cartogram` must contain `x, y`; `sources` must contain `x, y, value, id`.
The returned `x, y, id, weight, weight_mean` table contains source-normalized
transport weights and target-normalized contributions. The caller supplies an
instantiated `KernelAbstractions.Backend` such as `CPU()` or `CUDABackend()`.
CPU uses exact matrix-free reductions; accelerators conservatively truncate
negligible terms at low regularization while keeping convergence checks exact.
"""
function distribute(
    cartogram::AbstractDataFrame,
    sources::AbstractDataFrame;
    backend::KA.Backend,
)
    _validate_inputs(cartogram, sources)
    KA.functional(backend) === false && throw(ArgumentError(
        "the supplied KernelAbstractions backend is not functional",
    ))
    return _distribute(cartogram, sources, backend)
end

end
