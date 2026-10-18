module OWIDLayout

using CSV, JSON, SHA

include("identities.jl")
include("inputs.jl")
include("groups.jl")
include("group_population.jl")
include("group_resize.jl")
include("prepare_sources.jl")
include("partition.jl")
include("scope_splits.jl")
include("clean_layout.jl")
include("mapping_inputs.jl")
include("mapping_fit.jl")
include("mapping_export.jl")
include("build.jl")

export Piece, match_identities, read_sources, read_targets, read_target_groups
export build_layout, mapping_inputs, fit_pool, fit_export, export_mapping

end
