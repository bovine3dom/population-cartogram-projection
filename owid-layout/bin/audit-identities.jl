using OWIDLayout, CSV, JSON, SHA

length(ARGS) == 4 || error("Usage: audit-identities.jl OWID.csv components.csv polygons.geojson OUTPUT_DIR")
owid, components, polygons, output = ARGS
ispath(output) && error("Use a new output directory")
codes = OWIDLayout.code_table(joinpath(@__DIR__, "..", "config", "country-codes.csv"))
sources = read_sources(components, polygons, codes)
targets = read_targets(owid, codes)
results = NamedTuple[]; missing = String[]
for scope in sort!(collect(keys(targets)))
    if !haskey(sources,scope)
        push!(missing,scope)
        continue
    end
    append!(results, [(;scope,r...) for r in match_identities(sources[scope],targets[scope])])
end
# Reviewed identities are read only AFTER all matches have been computed.
expected = CSV.File(joinpath(@__DIR__, "..", "test", "fixtures", "expected-identities.csv"); types=String)
lookup = Dict(r.target_id => r.source_id for r in results)
checks = [(target_id="$(r.country):$(r.target_part)", name=r.name,
           expected=r.component_id, actual=get(lookup,"$(r.country):$(r.target_part)",""),
           passed=get(lookup,"$(r.country):$(r.target_part)","")==r.component_id) for r in expected]
inputs = [owid, components, polygons,
          joinpath(@__DIR__, "..", "config", "country-codes.csv"),
          joinpath(@__DIR__, "..", "src", "identities.jl"),
          joinpath(@__DIR__, "..", "src", "inputs.jl"),
          joinpath(@__DIR__, "..", "Manifest.toml"), @__FILE__]
hashes = Dict(normpath(p) => open(io -> bytes2hex(sha256(io)), p) for p in inputs)
mkdir(output)
CSV.write(joinpath(output,"candidates.csv"),results)
CSV.write(joinpath(output,"reviewed-checks.csv"),checks)
open(joinpath(output,"summary.json"),"w") do io
    JSON.print(io,(;stage="automatic identity baseline; not a layout export",
        targets=sum(length,values(targets)), candidates=length(results),
        checks_passed=count(r->r.passed,checks), checks_total=length(checks),
        missing_source_scopes=missing, input_sha256=hashes,
        population_weight=0.035, relationship_weight=0.05))
end
println("Reviewed identities recovered: $(count(r->r.passed,checks))/$(length(checks))")
