using Serialization
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame
const CE=ContinuityExperiment

length(ARGS)==2 || error("usage: contact_bounds.jl REGIONAL_STUDY_DIRECTORY NEW_OUTPUT.csv")
input,output=ARGS
ispath(output) && error("refusing to overwrite $output")
countries=deserialize(joinpath(input,"countries.jls"))
plans=deserialize(joinpath(input,"baseline.jls"))
raw=CSV.read(joinpath(input,"borders.csv"),DataFrame)
borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(raw))
codes=getproperty.(countries,:code)
all_pairs=Set(minmax(a,b) for a in codes for b in codes if a!=b)
edges=CE.graph(countries;borders=all_pairs)
pairs=sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k!=l]))
rows=NamedTuple[]
for (k,l) in pairs
    scoped=filter(e->e[1]==e[3] || minmax(e[1],e[3])==(k,l),edges)
    bound=ContinuityDiagnostics.source_separation_bound(countries[k],countries[l])
    m=CE.metrics(countries,plans,scoped)
    a,b=minmax(codes[k],codes[l])
    push!(rows,(;country_a=a,country_b=b,geographic=(a,b) in borders,
        cartogram_edges=count(e->e[1]!=e[3],scoped),minimum_cross_rms_km=bound,
        baseline_local_rms_p50=m.local_rms_p50,minimum_ratio_to_baseline_local=bound/max(m.local_rms_p50,1e-9),
        baseline_cross_rms_p50=m.cross_rms_p50))
end
CSV.write(output,DataFrame(rows))
println("Wrote $(length(rows)) contact bounds to $output")
