module OWIDLayout

using CSV, JSON, SHA

include("identities.jl")
include("inputs.jl")
include("groups.jl")
include("group_population.jl")
include("group_resize.jl")
include("prepare_sources.jl")
include("partition.jl")
include("region_exchange.jl")
include("region_seed.jl")
include("scope_splits.jl")
include("clean_layout.jl")

export Piece, match_identities, read_sources, read_targets, read_target_groups

end
