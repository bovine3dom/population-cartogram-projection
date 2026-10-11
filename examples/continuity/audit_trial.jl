using Serialization
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame
const CE=ContinuityExperiment

length(ARGS)==3 || error("usage: audit_trial.jl COUNTRIES.jls TRIAL_DIRECTORY NEW_OUTPUT")
source,trial,out=ARGS
ispath(out) && error("refusing to overwrite $out")
mkpath(out)
countries=deserialize(source)
saved=CE.saved_case(trial,countries;root=dirname(source))
edges=CE.graph(countries;borders=saved.borders)
bounds=ContinuityDiagnostics.capacity_rms_bounds(countries,edges)
CSV.write(joinpath(out,"bounds.csv"),bounds)
rows=NamedTuple[]
for name in ("baseline","candidate")
    plans=deserialize(joinpath(trial,"$name.jls"))
    all(p->all(x->isfinite(x)&&x>=0,p),plans) || error("invalid plan")
    source_error=maximum(maximum(abs.(vec(sum(p;dims=2))./c.a.-1)) for (c,p) in zip(countries,plans))
    m=CE.metrics(countries,plans,edges)
    source_error<=1e-8 && m.marginal_error<=get(saved.settings,:inner_tolerance,1e-5)+1e-10 &&
        m.target_max_relative<=.001+1e-10 || error("mass check failed")
    orientation=ContinuityDiagnostics.orientations(countries,plans)
    CSV.write(joinpath(out,"$name-orientation.csv"),orientation)
    CE.export_seams(joinpath(out,"$name-seams.csv"),countries,plans,edges)
    seams=isempty(bounds) ? DataFrame() : CSV.read(joinpath(out,"$name-seams.csv"),DataFrame)
    for r in eachrow(bounds)
        pair=minmax(r.country,r.neighbour)
        s=only(filter(s->minmax(s.country_a,s.country_b)==pair,eachrow(seams)))
        s.cross_rms_all+.001>=r.all_edge_rms_lower_bound_km &&
            s.cross_rms_p90+.001>=r.p90_rms_lower_bound_km || error("capacity bound violated")
    end
    push!(rows,(;name,source_max_relative=source_error,positive_triangles=sum(orientation.positive),
                positive_area_km2=sum(orientation.positive_area_km2),m...))
end
CSV.write(joinpath(out,"metrics.csv"),DataFrame(rows))
println("Mass and capacity checks passed: $trial")
