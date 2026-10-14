# Pack an already sparse mapping without importance-based row reduction.
using Arrow, H3, SHA, TOML
include("audit.jl")
include("write.jl")
const MA=MobileAudit
const ME=MA.ME

function pack_mapping(input,mapping,density_file,out)
    ispath(out) && error("output exists")
    staging=out*".pending";ispath(staging) && error("staging directory exists")
    paths=(input,mapping,density_file)
    digest(path)=bytes2hex(open(sha256,path))
    hashes=map(digest,paths)
    original=Arrow.Table(input);table=Arrow.Table(mapping)
    meta=ME.metadata(original.index_lower,original.index_upper,original.x,original.y,
        original.population,original.code,original.label)
    reference=MA.stats(table,meta);ownership=MA.stats(original,meta).owners
    maximum(abs.(reference.source_sum.-1))<=1e-7 || error("input source mass failed")
    reference.mean_error<=1e-7 && reference.mean_sum_error<=1e-7 || error("input target weights failed")
    source=Int32[meta.source_index[ME.cellid(lo,hi)] for (lo,hi) in zip(table.index_lower,table.index_upper)]
    target=Int32[meta.target_index[(Int(x),Int(y),Int(c))] for (x,y,c) in zip(table.x,table.y,table.code)]
    labels=Dict(i=>String(table.label[i]) for i in eachindex(table.label) if !ismissing(table.label[i]))
    part=(;meta,source,target,weights=Float64.(table.weight),labels)
    counts=Dict{Tuple{Int,Int},Int}()
    for (x,y,_) in meta.targets
        counts[(x,y)]=get(counts,(x,y),0)+1
    end
    owners=Dict(key=>ownership[key] for (key,count) in counts if count>1)
    density=Arrow.Table(density_file);seen=Set{UInt64}()
    eltype(density.index_lower)==UInt32 && eltype(density.index_upper)==UInt32 || error("wrong density H3 type")
    for (lo,hi,value) in zip(density.index_lower,density.index_upper,density.value)
        id=ME.cellid(lo,hi);id in seen && error("duplicate density cell");push!(seen,id)
        isfinite(value) && value>0 || error("invalid density")
        isapprox(value,meta.population[meta.source_index[id]]/H3.API.cellAreaKm2(id);rtol=1e-12) || error("density changed")
    end
    seen==Set(meta.ids) || error("density coverage changed")
    mkpath(staging)
    transport=joinpath(staging,"cartogram_weights_hilo.arrow")
    packed=MobileWriter.write_file(transport,[part];owners,dictionary=true,source_order=true)
    density_bytes=MobileWriter.write_density(joinpath(staging,"population_density_hilo.arrow"),density_file)
    result=Arrow.Table(transport);checked=MA.stats(result,meta)
    source_error=maximum(abs.(checked.source_sum.-1))
    mass_error=maximum(abs.(checked.mass./reference.mass.-1))
    forward=maximum(sqrt.(vec(sum(abs2,checked.source_xy.-reference.source_xy;dims=1))))
    inverse=6371maximum(sqrt.(vec(sum(abs2,checked.xyz.-reference.xyz;dims=1))))
    tv=maximum(MA.variation(result,table,meta,checked,reference))
    source_error<=1e-7 && mass_error<=1e-7 || error("packed mass check failed")
    checked.mean_error<=1e-7 && checked.mean_sum_error<=1e-7 || error("packed target weights failed")
    forward<=.002 && inverse<=.002 && tv<=1e-6 || error("packing changed the mapping")
    checked.labels==reference.labels || error("city anchors changed")
    checked.owners==ownership || error("original shared-cell ownership changed")
    map(digest,paths)==hashes || error("input changed during packing")
    report=Dict("rows"=>packed.rows,"transport_bytes"=>packed.bytes,"density_bytes"=>density_bytes,
        "sources"=>length(meta.ids),"labels"=>length(checked.labels),"ownership_rows"=>packed.ownership_rows,
        "negligible_rows_dropped"=>packed.dropped_rows,"source_sum_error"=>source_error,
        "target_mass_relative_error"=>mass_error,"forward_error"=>forward,"inverse_error_km"=>inverse,
        "target_tv_max"=>tv,"input_sha256"=>hashes[1],"mapping_sha256"=>hashes[2],"density_sha256"=>hashes[3],
        "transport_sha256"=>digest(transport),"moment_reduction"=>false,
        "row_order"=>"target anchors first, then source H3, x, y")
    open(io->TOML.print(io,report),joinpath(staging,"packing.toml"),"w")
    mv(staging,out)
    return report
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==4 || error("usage: pack_mapping.jl ORIGINAL_INPUT SPARSE_MAPPING DENSITY NEW_OUTPUT")
    println(pack_mapping(ARGS...))
end
