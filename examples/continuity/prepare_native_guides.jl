using Serialization,Arrow,Dates
include("mobile_export.jl")
include("mobile/audit.jl")
const ME=MobileExport
function main()
 length(ARGS)==3 || error("usage: prepare_native_guides.jl COARSE_INPUT.arrow REFERENCE.arrow OUTPUT")
 input,reference,out=ARGS;ispath(out)&&error("output exists");mkpath(out)
 data=ME.load_index(input,reference,joinpath(out,"index.jls"))
 for code in sort(unique(data.meta.codes))
  guide=ME.country_data(data,code);serialize(joinpath(out,"country-$code.jls"),guide)
 end
 original=Arrow.Table(input);owners=MobileAudit.stats(original,data.meta).owners
 codes=Dict{Tuple{Int,Int},Set{Int}}()
 for (x,y,c) in data.meta.targets;push!(get!(codes,(x,y),Set{Int}()),c);end
 shared=Dict(key=>owners[key] for (key,cs) in codes if length(cs)>1)
 serialize(joinpath(out,"owners.jls"),shared)
 serialize(joinpath(out,"codes.jls"),sort(unique(data.meta.codes)))
 println((;countries=length(unique(data.meta.codes)),shared=length(shared),time=now(UTC)))
end
main()
