using Arrow,Serialization,SHA,TOML,CSV,Dates
include("native_export.jl")
const NE=NativeExport
const MA=NE.MA
function navigation(table)
    result=Dict{Tuple{Int,Int},UInt64}()
    for r in eachindex(table.weight)
        key=(Int(table.x[r]),Int(table.y[r]))
        haskey(result,key)||(result[key]=MA.ME.cellid(table.index_lower[r],table.index_upper[r]))
    end
    result
end
function main()
    length(ARGS)==4||error("usage: audit_native_packing.jl ORIGINAL_EXPORT PACKED_EXPORT NATIVE_INPUT NEW_REPORT")
    original,candidate,native,report=ARGS;ispath(report)&&error("report exists")
    base=TOML.parsefile(joinpath(original,"audit.toml"));audit=TOML.parsefile(joinpath(candidate,"audit.toml"))
    base["factor"]==audit["factor"]&&base["native_sha256"]==audit["native_sha256"]||error("inputs differ")
    config=TOML.parsefile(joinpath(candidate,"fit-input.toml"))
    config["fit_sha256"]==base["parts_sha256"]||error("packing reference differs")
    paths=[joinpath(dir,"cartogram_weights_hilo.arrow") for dir in (original,candidate)]
    hashes=NE.hash.(paths)
    hashes==[base["transport_sha256"],audit["transport_sha256"]]||error("binary hash differs")
    NE.hash(native)==audit["native_sha256"]||error("native input hash differs")
    codes=sort(config["codes"])
    parts=[deserialize(joinpath(audit["root"],"country-$code","part.jls")) for code in codes]
    meta=NE.metadata(parts,Arrow.Table(native))
    names,fields=MA.MobileQuality.probe_fields(meta)
    full_table,reduced_table=Arrow.Table.(paths)
    full=MA.stats(full_table,meta;fields);reduced=MA.stats(reduced_table,meta;fields)
    full.labels==reduced.labels||error("city anchor changed")
    full.owners==reduced.owners||error("country owner changed")
    navigation(full_table)==navigation(reduced_table)||error("navigation anchor changed")
    tv=MA.variation(reduced_table,full_table,meta,reduced,full)
    maximum(tv)<=1-config["target_retained"]+2e-5||error("target variation exceeded")
    forward=maximum(abs.(reduced.source_xy.-full.source_xy))/audit["factor"]
    forward<=config["forward_tolerance"]+1e-5||error("source mean bound exceeded")
    inverse=maximum(6371sqrt.(vec(sum(abs2,reduced.xyz.-full.xyz;dims=1))))
    mass=maximum(abs.(reduced.mass./full.mass.-1));density=maximum(abs.(reduced.density./full.density.-1))
    inverse<=.002&&mass<=2e-5&&density<=2e-5||error("binary moment bound exceeded")
    query=report*".queries.csv"
    CSV.write(query,MA.MobileQuality.compare_values(full.probe_values,full.probe_mass,reduced.probe_values,reduced.probe_mass,names,fields))
    NE.hash.(paths)==hashes||error("binary input changed")
    result=Dict("reference_sha256"=>hashes[1],"transport_sha256"=>hashes[2],"parts_sha256"=>audit["parts_sha256"],
        "target_tv_max"=>maximum(tv),"forward_coordinate_coarse_max"=>forward,"geographic_km_max"=>inverse,
        "mass_relative_max"=>mass,"density_relative_max"=>density,"anchors_equal"=>true,
        "query_sha256"=>NE.hash(query),"utc"=>string(now(UTC)))
    open(io->TOML.print(io,result),report,"w");println(result)
end
if abspath(PROGRAM_FILE)==@__FILE__;main();end
