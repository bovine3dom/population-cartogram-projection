module OWIDLayout

using CSV, JSON

include("identities.jl")
include("inputs.jl")

export Piece, match_identities, read_sources, read_targets

end
