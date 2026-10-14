# Audit an immutable fit checkpoint. This does not publish or modify the fit.
using Serialization, SHA, TOML, Dates
include("experiment.jl")
include("diagnostics.jl")
const CE=ContinuityExperiment
const CD=ContinuityDiagnostics
const CS=CE.ContinuitySharpness
using .CE: CSV,DataFrame

function audit_sharpness(root,checkpoint,original_sources,report)
    ispath(report) && error("report exists")
    digest(path)=bytes2hex(open(sha256,path))
    checkpoint_hash=digest(checkpoint);original_hash=digest(original_sources)
    countries=deserialize(joinpath(root,"countries.jls"))
    saved=deserialize(checkpoint)
    plans=hasproperty(saved,:plans) ? saved.plans : saved
    length(plans)==length(countries) || error("country count differs")
    (;settings,borders,border_factors)=CE.saved_case(joinpath(root,"fit"),countries;root)
    rows=NamedTuple[]
    for (c,p) in zip(countries,plans)
        CE.compact_stats!(p,c)
        maximum(abs.(p.stats.source./c.a.-1))<=1e-8 || error("source mass failed: $(c.code)")
        sum(abs.(p.stats.target.-c.b))<=settings[:inner_tolerance]+1e-10 || error("target L1 failed: $(c.code)")
        maximum(abs.(p.stats.target./c.b.-1))<=.001 || error("target relative mass failed: $(c.code)")
        append!(rows,CS.plan_rows(c,p,(p,r)->exp.(CE.logblock(p,r))))
        println(now(UTC)," audited ",c.code);flush(stdout)
    end
    codes=Set(getproperty.(countries,:code))
    original=filter(r->r.code in codes,collect(CSV.File(original_sources)))
    Set((r.code,r.id) for r in rows)==Set((r.code,r.id) for r in original) || error("source identities differ")
    reference=Dict((r.code,r.id)=>r.population for r in original)
    all(r.population==reference[(r.code,r.id)] for r in rows) || error("source population differs")
    targets=sum(length(c.b) for c in countries)
    edges=CE.graph(countries;borders)
    weights=CE.edge_weights(edges,settings[:border_share])
    weights .*= [k==l ? settings[:internal_scale] : settings[:border_scale]*get(border_factors,minmax(countries[k].code,countries[l].code),1.) for (k,j,l,t) in edges]
    etas=[get(get(settings,:country_etas,Dict()),c.code,settings[:eta]) for c in countries]
    settings[:preserve_displacements] && error("displacement-reference audit is not implemented")
    objective=CE.objective(countries,plans,edges,settings[:strength],etas;
        weights,scale_km=settings[:scale_km],form=settings[:form],internal_form=settings[:internal_form],saturating=settings[:saturating])
    objective+=settings[:fold_strength]*first(CE.fold_penalty_gradient(countries,plans,CE.triangles(countries);
        smoothing_area=settings[:fold_smoothing],forces_only=true))
    if hasproperty(saved,:metrics)
        isapprox(objective,last(saved.metrics).objective;atol=1e-8,rtol=1e-9) || error("snapshot objective differs")
        all(diff(getproperty.(saved.metrics,:objective)).<=1e-10) || error("objective increased")
    end
    orientation=CD.orientations(countries,plans;moments=(c,p)->p.stats.moment)
    asdict(value)=Dict(string(k)=>v for (k,v) in pairs(value))
    digest(checkpoint)==checkpoint_hash && digest(original_sources)==original_hash || error("audit inputs changed")
    result=Dict("checkpoint"=>abspath(checkpoint),"checkpoint_sha256"=>checkpoint_hash,
        "original_sources_sha256"=>original_hash,
        "iteration"=>(hasproperty(saved,:iteration) ? saved.iteration : -1),
        "start_step"=>(hasproperty(saved,:start_step) ? saved.start_step : -1),
        "objective"=>objective,"source"=>asdict(CS.summarize(rows,targets)),
        "original_source"=>asdict(CS.summarize(original,targets)),
        "continuity"=>asdict(CE.metrics(countries,plans,edges)),
        "positive_triangles"=>sum(orientation.positive),"positive_area_km2"=>sum(orientation.positive_area_km2))
    mkpath(dirname(report))
    CSV.write(report*".sources.csv",DataFrame(rows))
    CSV.write(report*".orientations.csv",orientation)
    open(io->TOML.print(io,result),report,"w")
    return result
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==4 || error("usage: audit_sharpness.jl FIT_ROOT IMMUTABLE_CHECKPOINT ORIGINAL_SOURCE_CSV NEW_REPORT_TOML")
    audit_sharpness(ARGS...)
end
