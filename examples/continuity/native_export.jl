module NativeExport
using Arrow,CSV,H3,SHA,TOML,Serialization,Statistics,LinearAlgebra,Dates
include("mobile/audit.jl")
include("mobile/write.jl")
const MA=MobileAudit
const ME=MA.ME
const MW=MobileWriter
hash(path)=bytes2hex(open(sha256,path))

function metadata(parts,native)
    ids=UInt64.(native.id);allunique(ids)||error("duplicate native source")
    all(id->H3.API.isValidCell(id)&&H3.API.getResolution(id)==6,ids)||error("expected H3-6")
    population=Float64.(native.population);codes=Int.(native.country_code)
    all(p->isfinite(p)&&p>0,population)||error("invalid native population")
    source_index=Dict(id=>Int32(i) for (i,id) in enumerate(ids))
    targets=Tuple{Int,Int,Int}[];labels=Dict{Int32,String}();seen=Set{UInt64}();xyz=zeros(3,length(ids))
    for part in parts
        meta=part.meta;append!(targets,meta.targets)
        for (i,id) in enumerate(meta.ids)
            id in seen&&error("duplicate country source");push!(seen,id);s=source_index[id]
            meta.population[i]==population[s]&&meta.codes[i]==codes[s]||error("native metadata differs")
        end
        for (i,name) in meta.labels;labels[source_index[meta.ids[i]]]=name;end
    end
    seen==Set(ids)&&allunique(targets)||error("native coverage differs")
    for (s,id) in enumerate(ids)
        g=H3.API.cellToLatLng(id);xyz[:,s]=[cos(g.lat)*cos(g.lng),cos(g.lat)*sin(g.lng),sin(g.lat)]
    end
    target_index=Dict(t=>Int32(j) for (j,t) in enumerate(targets))
    (;ids,population,codes,source_index,targets,target_index,xyz,labels)
end

function check_labels(parts,guides)
    for part in parts
        code=only(unique(part.meta.codes));guide=deserialize(joinpath(guides,"country-$code.jls"))
        expected=Dict{Int32,String}();largest=Dict{UInt64,Int}()
        for (i,id) in enumerate(part.meta.ids)
            parent=H3.API.cellToParent(id,5);old=get(largest,parent,0)
            (old==0||part.meta.population[i]>part.meta.population[old])&&(largest[parent]=i)
        end
        for (old,name) in guide.meta.labels
            parent=guide.meta.ids[old];i=get(largest,parent,0)
            i==0&&(i=argmin(vec(sum(abs2,part.meta.xyz.-guide.meta.xyz[:,old];dims=1))))
            expected[i]=haskey(expected,i) ? expected[i]*", "*name : name
        end
        expected==part.meta.labels||error("city labels differ for $code")
    end
end

# Use dictionaries only when they reduce the raw column payload.
function dictionary_columns(table)
    map(table) do col
        T=eltype(col)
        if T<:Number
            count=length(unique(col));width=count<=128 ? 1 : count<=32768 ? 2 : 4
            width*length(col)+count*sizeof(T)<length(col)*sizeof(T) ? Arrow.DictEncode(col) : col
        else
            Arrow.DictEncode(col)
        end
    end
end

function export_native(root,native_dir,guides,out;factor=1)
    isfile(joinpath(root,"fit-complete.txt"))||error("fit is incomplete")
    ispath(out)&&error("output exists");pending=out*".pending";ispath(pending)&&error("staging exists")
    codes=sort(deserialize(joinpath(guides,"codes.jls")))
    native_path=joinpath(native_dir,"all-res6.arrow");input_hash=hash(native_path)
    native=Arrow.Table(native_path);sort(unique(Int.(native.country_code)))==codes||error("country coverage differs")
    parts=[deserialize(joinpath(root,"country-$code","part.jls")) for code in codes]
    check_labels(parts,guides);meta=metadata(parts,native)
    owners=deserialize(joinpath(guides,"owners.jls"))
    if factor!=1
        owners=Dict((factor*x+2ix-factor-1,factor*y+2iy-factor-1)=>code for ((x,y),code) in owners for ix in 1:factor for iy in 1:factor)
    end
    for part in parts
        code=only(unique(part.meta.codes));guide=deserialize(joinpath(guides,"country-$code.jls"))
        expected=Set((factor*x+2ix-factor-1,factor*y+2iy-factor-1,c) for (x,y,c) in guide.meta.targets for ix in 1:factor for iy in 1:factor)
        Set(part.meta.targets)==expected||error("target coverage differs for $code")
    end
    mkpath(pending);counts=Ref((;dropped_rows=0,ownership_rows=0))
    table=MW.columns(parts;owners,counts)
    # Retain target navigation anchors before ordering the other rows by source.
    anchors=Int[];seen=Set{Tuple{Int16,Int16}}()
    for i in eachindex(table.weight)
        key=(table.x[i],table.y[i]);key in seen&&continue;push!(seen,key);push!(anchors,i)
    end
    anchor_set=Set(anchors)
    order=let upper=table.index_upper,lower=table.index_lower,x=table.x,y=table.y
        sortperm(eachindex(upper);by=i->(upper[i],lower[i],x[i],y[i]))
    end
    filter!(i->i∉anchor_set,order);order=vcat(anchors,order)
    table=map(col->col[order],table)
    transport=joinpath(pending,"cartogram_weights_hilo.arrow")
    Arrow.write(transport,dictionary_columns(table);ntasks=1)
    density_path=joinpath(pending,"population_density_hilo.arrow")
    density=meta.population./H3.API.cellAreaKm2.(meta.ids)
    Arrow.write(density_path,dictionary_columns((;index_lower=UInt32.(meta.ids.&0xffffffff),index_upper=UInt32.(meta.ids.>>32),value=Float32.(density)));ntasks=1)
    binary=Arrow.Table(transport)
    Tuple(propertynames(binary))==keys(table)||error("transport schema differs")
    for name in keys(table)
        a,b=getproperty(binary,name),getproperty(table,name)
        eltype(a)==eltype(b)&&length(a)==length(b)&&all(isequal(x,y) for (x,y) in zip(a,b))||error("binary column differs: $name")
    end
    checked=MA.stats(binary,meta)
    source_error=maximum(abs.(checked.source_sum.-1))
    source_error<=1e-7&&checked.mean_error<=1e-7&&checked.mean_sum_error<=1e-7||error("binary weights failed")
    all(checked.owners[(Int(x),Int(y))]==code for ((x,y),code) in owners)||error("shared-cell ownership differs")
    reports=NamedTuple[]
    for code in codes
        source_ids=findall(==(code),meta.codes);target_ids=findall(t->t[3]==code,meta.targets)
        b=checked.mass[target_ids]./sum(meta.population[source_ids]);expected=1/length(b)
        l1=sum(abs.(b.-expected));relative=maximum(abs.(b./expected.-1))
        l1<=1.001e-4&&relative<=.001001||error("binary country mass failed: $code")
        push!(reports,(;code,sources=length(source_ids),targets=length(target_ids),population=sum(meta.population[source_ids]),target_l1=l1,target_relative=relative))
    end
    dt=Arrow.Table(density_path)
    eltype(dt.index_lower)==UInt32&&eltype(dt.index_upper)==UInt32||error("density H3 types differ")
    density_error=0.;density_seen=Set{UInt64}()
    for r in eachindex(dt.value)
        id=ME.cellid(dt.index_lower[r],dt.index_upper[r]);id in density_seen&&error("duplicate density");push!(density_seen,id)
        s=meta.source_index[id];v=dt.value[r];isfinite(v)&&v>0||error("invalid density")
        density_error=max(density_error,abs(v/density[s]-1))
    end
    density_seen==Set(meta.ids)&&density_error<=6e-8||error("density check failed")
    CSV.write(joinpath(pending,"country-mass.csv"),reports)
    cp(joinpath(root,"summary.csv"),joinpath(pending,"fit-countries.csv"))
    report=Dict("resolution"=>6,"factor"=>factor,"sources"=>length(meta.ids),"country_targets"=>length(meta.targets),"physical_targets"=>length(seen),
        "countries"=>length(codes),"rows"=>length(table.weight),"labelled_sources"=>length(meta.labels),"population"=>sum(meta.population),
        "source_error"=>source_error,"physical_mean_error"=>checked.mean_error,"physical_mean_sum_error"=>checked.mean_sum_error,
        "density_relative_error"=>density_error,"density_type"=>"Float32","transport_bytes"=>filesize(transport),"density_bytes"=>filesize(density_path),
        "native_sha256"=>input_hash,"transport_sha256"=>hash(transport),"density_sha256"=>hash(density_path),
        "root"=>abspath(root),"guides"=>abspath(guides),"commit"=>strip(read(`git rev-parse HEAD`,String)),"utc"=>string(now(UTC)),
        "model"=>"Native-source refinement of the sharp H3-5 continuity map; not a new global border pass")
    open(io->TOML.print(io,report),joinpath(pending,"audit.toml"),"w")
    hash(native_path)==input_hash||error("native input changed")
    mv(pending,out);report
end
end
if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS) in (4,5)||error("usage: native_export.jl FIT NATIVE GUIDES NEW_OUTPUT [FACTOR]")
    println(NativeExport.export_native(ARGS[1:4]...;factor=length(ARGS)==5 ? parse(Int,ARGS[5]) : 1))
end
