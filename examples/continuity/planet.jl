# Whole-planet research workflow. Keep production inputs and exports separate.
using Serialization, Dates, SHA, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: Arrow, CSV, DataFrame, H3, groupby, nrow, select, combine, transform!, dot
const CE=ContinuityExperiment

function input_frame(path)
    d=DataFrame(Arrow.Table(path);copycols=true)
    d.id=(UInt64.(d.index_upper).<<32).|UInt64.(d.index_lower)
    all(id->H3.API.isValidCell(id) && H3.API.getResolution(id)==5,d.id) || error("expected H3-5")
    all(x->isfinite(x)&&x>0,d.population) || error("invalid population")
    sources=unique(select(d,:id,:population,:code))
    allunique(sources.id) || error("source population or country is ambiguous")
    return d
end

function prepare(input,out)
    ispath(out) && error("refusing to overwrite $out")
    d=input_frame(input)
    mkpath(out)
    cp(input,joinpath(out,"input.arrow"))
    write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nInput: $(abspath(input))\nSHA256: $(bytes2hex(open(sha256,input)))\nCommit: "*read(`git rev-parse HEAD`,String))
    codes=sort!(Int.(unique(d.code)))
    boundary=joinpath(@__DIR__,"..","..","make-lookup-table","population-data","country-boundaries","ne_10m_admin_0_map_units.geojson")
    script=joinpath(@__DIR__,"shared_borders.py")
    borderpath=joinpath(out,"borders.csv")
    run(`python $script $boundary $borderpath $codes`)
    br=CSV.read(borderpath,DataFrame)
    borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(br))
    targets=[(;code,target=unique(select(filter(r->r.code==code,d),:x,:y))) for code in codes]
    allpairs=Set(minmax(a,b) for a in codes for b in codes if a!=b)
    contacts=Dict{Tuple{Int,Int},Int}()
    for (k,j,l,t) in CE.graph(targets;borders=allpairs)
        k==l && continue
        pair=minmax(codes[k],codes[l])
        contacts[pair]=get(contacts,pair,0)+1
    end
    rows=[(;country_a=a,country_b=b,edges=get(contacts,(a,b),0),geographic=(a,b) in borders,
            fitted=(a,b) in borders && get(contacts,(a,b),0)>0)
          for (a,b) in sort!(collect(union(borders,keys(contacts))))]
    CSV.write(joinpath(out,"contacts.csv"),DataFrame(rows))
    active=Set(v for r in rows if r.fitted for v in (r.country_a,r.country_b))
    counts=NamedTuple[]
    mkpath(joinpath(out,"sources"))
    for c in targets
        raw=filter(r->r.code==c.code,d)
        s=unique(select(raw,:id,:population))
        s.country_code=fill(c.code,nrow(s))
        Arrow.write(joinpath(out,"sources","$(c.code).arrow"),s)
        push!(counts,(;code=c.code,sources=nrow(s),targets=nrow(c.target),fitted=c.code in active,
                       dense_bytes=8nrow(s)*nrow(c.target)))
    end
    CSV.write(joinpath(out,"countries.csv"),DataFrame(counts))
    CE.checkpoint(joinpath(out,"targets.jls"),targets)
    println("Prepared $(length(codes)) countries; $(length(active)) have a true artwork contact.")
    println("One dense plan for active countries: $(sum(r.dense_bytes for r in counts if r.fitted)/1e9) GB")
end

function local_factors(countries,plans,edges)
    q=[CE.means(c,p) for (c,p) in zip(countries,plans)]
    rms2(e)=begin
        k,j,l,t=e
        6371^2*max(0.,2-2dot(q[k][:,j],q[l][:,t]))
    end
    pairs=sort!(unique([minmax(k,l) for (k,j,l,t) in edges if k!=l]))
    factors=Dict{Tuple{Int,Int},Float64}()
    counts=Dict{Tuple{Int,Int},Int}()
    for pair in pairs
        cross=filter(e->e[1]!=e[3] && minmax(e[1],e[3])==pair,edges)
        endpoints=Set(v for (k,j,l,t) in cross for v in ((k,j),(l,t)))
        nearby=filter(e->e[1]==e[3] && ((e[1],e[2]) in endpoints || (e[3],e[4]) in endpoints),edges)
        scale2=isempty(nearby) ? 900.0^2 : max(1.,sum(rms2,nearby)/length(nearby))
        key=minmax(countries[pair[1]].code,countries[pair[2]].code)
        factors[key]=1/scale2
        counts[key]=length(cross)
    end
    norm=sum(values(counts))/sum(counts[p]*f for (p,f) in factors)
    return Dict(p=>f*norm for (p,f) in factors)
end

include("planet_fit.jl")

function assemble(original,replacement)
    active=Set(replacement.code)
    unchanged=select(filter(r->!(r.code in active),original),:x,:y,:id,:code,:weight,:weight_mean)
    d=vcat(replacement,unchanged)
    sources=unique(select(original,:id,:population,:code))
    population=Dict(r.id=>r.population for r in eachrow(sources))
    Set(d.id)==Set(sources.id) || error("source coverage changed")
    Set(zip(d.x,d.y,d.code))==Set(zip(original.x,original.y,original.code)) || error("target coverage changed")
    all(w->isfinite(w)&&w>0,d.weight) || error("invalid source weight")
    d.population=[population[id] for id in d.id]
    # Remove legacy row-sum drift and renormalize the small sparse-export tail.
    transform!(groupby(d,:id),:weight=>(v->v./sum(v))=>:weight)
    d.weight_mean=d.weight.*d.population
    transform!(groupby(d,[:x,:y]),:weight_mean=>(v->v./sum(v))=>:weight_mean)
    labels=Dict{UInt64,Vector{String}}()
    for r in eachrow(original)
        ismissing(r.label) || push!(get!(labels,r.id,String[]),r.label)
    end
    d.label=Vector{Union{Missing,String}}(missing,nrow(d))
    groups=groupby(d,:id)
    for (id,names) in labels
        rows=groups[(id=id,)]
        rows.label[argmax(rows.weight)]=join(unique(names),", ")
    end
    d.prominence=Vector{Union{Missing,Float64}}(missing,nrow(d))
    d.index_lower=UInt32.(d.id .& 0xffffffff);d.index_upper=UInt32.(d.id .>> 32)
    return select(d,:x,:y,:weight,:population,:code,:label,:weight_mean,:index_lower,:index_upper,:prominence),sources
end

function publish(out,destination)
    isfile(joinpath(out,"fit-complete.txt")) || error("fit is not complete")
    ispath(destination) && error("refusing to overwrite $destination")
    staging=destination*".pending"
    ispath(staging) && error("staging directory exists: $staging")
    countries=deserialize(joinpath(out,"countries.jls"))
    plans=deserialize(joinpath(out,"fit","candidate.jls"))
    for (c,p) in zip(countries,plans)
        p isa CE.CompactPlan && CE.compact_stats!(p,c)
        CE.valid_plan(p) || error("invalid plan")
        maximum(abs.(vec(sum(p;dims=2))./c.a.-1))<=1e-8 || error("source mass check failed")
        totals=vec(sum(p;dims=1))
        sum(abs.(totals.-c.b))<=1e-4 && maximum(abs.(totals./c.b.-1))<=.001 || error("target mass check failed")
    end
    orientation=ContinuityDiagnostics.orientations(countries,plans;
        moments=(c,p)->p isa CE.CompactPlan ? p.stats.moment : c.xyz*p)
    CSV.write(joinpath(out,"candidate-orientation.csv"),orientation)
    rawpath=joinpath(out,"candidate.arrow")
    CE.export_mapping(rawpath,countries,plans;retained=.99999)
    raw=DataFrame(Arrow.Table(rawpath))
    d,sources=assemble(input_frame(joinpath(out,"input.arrow")),raw)
    mkpath(staging)
    Arrow.write(joinpath(staging,"cartogram_weights_planet_h3_5_factor1_continuity_hilo.arrow"),d)
    Arrow.write(joinpath(staging,"population_density_hilo.arrow"),(
        index_lower=UInt32.(sources.id .& 0xffffffff),index_upper=UInt32.(sources.id .>> 32),
        value=sources.population./H3.API.cellAreaKm2.(sources.id)))
    for name in ("provenance.txt","contacts.csv","countries.csv","candidate-orientation.csv")
        cp(joinpath(out,name),joinpath(staging,name))
    end
    for name in ("metrics.csv","settings.csv","baseline-seams.csv","candidate-seams.csv")
        cp(joinpath(out,"fit",name),joinpath(staging,name))
    end
    eta_file=joinpath(out,"fit","country-etas.csv")
    isfile(eta_file) && cp(eta_file,joinpath(staging,"country-etas.csv"))
    cp(joinpath(@__DIR__,"planet.md"),joinpath(staging,"README.md"))
    cp(joinpath(@__DIR__,"compact.md"),joinpath(staging,"compact.md"))
    isfile(joinpath(out,"fit-config.csv")) && cp(joinpath(out,"fit-config.csv"),joinpath(staging,"fit-config.csv"))
    # Publish only after both Arrow files and the diagnostics are complete.
    mv(staging,destination)
    println("Published $(nrow(d)) rows and $(nrow(sources)) sources to $destination")
    write(joinpath(out,"published.txt"),"$(now(UTC)) UTC\n$(abspath(destination))\n")
end

if abspath(PROGRAM_FILE)==@__FILE__
    if length(ARGS)==3 && ARGS[1]=="prepare"
        prepare(ARGS[2],ARGS[3])
    elseif length(ARGS)==2 && ARGS[1] in ("fit","fit-compact")
        fit(ARGS[2];compact=ARGS[1]=="fit-compact")
    elseif length(ARGS)==3 && ARGS[1]=="publish"
        publish(ARGS[2],ARGS[3])
    else
        error("usage: planet.jl prepare INPUT.arrow NEW_OUT | fit OUT | fit-compact OUT | publish OUT NEW_H3_MON_FOLDER")
    end
end
