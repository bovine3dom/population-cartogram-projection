# Manifest columns: code,cache,result. An empty result keeps the reference rows.
using Arrow, CSV, Serialization, SHA, TOML
include("reduce.jl")
include("write.jl")
include("quality.jl")

function prepare_part(cache,result)
    data=deserialize(cache)
    reduced=ismissing(result) ? (;rows=Int32.(eachindex(data.weight)),weights=data.weight) : deserialize(result)
    reference=ME.reference_stats(data)
    target_retained=get(reduced,:target_retained,0.)
    summary=merge(ME.evaluate(data,reduced.rows,reference;weights=reduced.weights),(;target_retained))
    validate(summary;target_retained)
    names,fields=MobileQuality.probe_fields(data.meta)
    quality=MobileQuality.compare_fields(data,reduced.rows,reduced.weights,names,fields)
    ownership=NamedTuple[]
    for (t,(x,y,code)) in enumerate(data.meta.targets)
        rows=view(data.index.target_rows,data.index.target_ptr[t]:data.index.target_ptr[t+1]-1)
        push!(ownership,(;x,y,code,count=length(rows),first=minimum(data.original_rows[r] for r in rows)))
    end
    return MobileWriter.select_part(data,reduced),summary,quality,ownership
end

function pack(manifest,input,density,out)
    ispath(out) && error("refusing to replace $out")
    original=Arrow.Table(input)
    expected=ME.metadata(original.index_lower,original.index_upper,original.x,original.y,
        original.population,original.code,original.label)
    parts=NamedTuple[];summaries=NamedTuple[];qualities=NamedTuple[];provenance=NamedTuple[]
    ownership=Dict{Tuple{Int,Int},Vector{NamedTuple}}();seen=Set{Int}()
    for row in CSV.File(manifest)
        row.code in seen && error("duplicate country")
        push!(seen,row.code)
        part,summary,quality,entries=prepare_part(row.cache,row.result)
        all(==(row.code),part.meta.codes) || error("wrong country cache")
        push!(parts,part);push!(summaries,merge((;code=row.code),summary))
        append!(qualities,[merge((;code=row.code),q) for q in quality])
        for entry in entries
            push!(get!(ownership,(entry.x,entry.y),NamedTuple[]),entry)
        end
        push!(provenance,(;code=row.code,cache=abspath(row.cache),result=ismissing(row.result) ? "reference" : abspath(row.result),
            sha256=ismissing(row.result) ? open(bytes2hex∘sha256,row.cache) : open(bytes2hex∘sha256,row.result)))
        println((;code=row.code,summary.rows));flush(stdout);GC.gc()
    end
    ids=reduce(vcat,[p.meta.ids for p in parts])
    length(ids)==length(unique(ids)) && Set(ids)==Set(expected.ids) || error("source coverage changed")
    Set(t for p in parts for t in p.meta.targets)==Set(expected.targets) || error("target coverage changed")
    labels=Dict(p.meta.ids[s]=>name for p in parts for (s,name) in p.meta.labels)
    labels==Dict(expected.ids[s]=>name for (s,name) in expected.labels) || error("labels changed")
    for p in parts, (s,id) in enumerate(p.meta.ids)
        i=expected.source_index[id]
        p.meta.population[s]==expected.population[i] && p.meta.codes[s]==expected.codes[i] || error("source metadata changed")
    end
    owners=Dict(key=>first(sort(entries;by=e->(-e.count,e.first))).code for (key,entries) in ownership if length(entries)>1)
    mkpath(out)
    report=MobileWriter.write_file(joinpath(out,"cartogram_weights_planet_h3_5_factor1_continuity_hilo.arrow"),parts;owners,dictionary=true,source_order=true)
    density_bytes=MobileWriter.write_density(joinpath(out,"population_density_hilo.arrow"),density)
    CSV.write(joinpath(out,"countries.csv"),summaries)
    CSV.write(joinpath(out,"query-errors.csv"),qualities)
    CSV.write(joinpath(out,"provenance.csv"),provenance)
    CSV.write(joinpath(out,"shared-cell-owners.csv"),[(;x=k[1],y=k[2],code=v) for (k,v) in owners])
    open(joinpath(out,"export.toml"),"w") do io
        TOML.print(io,Dict("rows"=>report.rows,"transport_bytes"=>report.bytes,"density_bytes"=>density_bytes,
            "ownership_rows"=>report.ownership_rows,"negligible_rows_dropped"=>report.dropped_rows,"sources"=>length(ids),"country_targets"=>length(expected.targets),
            "labels"=>length(labels),"approximate"=>true,"row_order"=>"target anchors first, then source H3, x, y","dictionary_columns"=>["index_lower","population","label"],"density_dictionary_columns"=>["index_lower"],
            "input_sha256"=>open(bytes2hex∘sha256,input),
            "manifest_sha256"=>open(bytes2hex∘sha256,manifest)))
    end
    println(report)
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==4 || error("usage: pack.jl MANIFEST INPUT_ARROW DENSITY_ARROW NEW_OUTPUT")
    pack(ARGS...)
end
