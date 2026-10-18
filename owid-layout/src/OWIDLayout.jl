module OWIDLayout

using CSV, JSON

include("identities.jl")
include("inputs.jl")
include("groups.jl")

export Piece, match_identities, read_sources, read_targets, read_target_groups

end
