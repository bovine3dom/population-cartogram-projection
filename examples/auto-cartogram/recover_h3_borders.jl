#!/usr/bin/env julia
# Inspect an interrupted sweep before solving its next update.
using JSON, SHA, Serialization, oneAPI
include(joinpath(@__DIR__,"..","continuity","experiment.jl"))
using .ContinuityExperiment: CSV, DataFrame, nrow
const CE=ContinuityExperiment

function interrupted_state(root)
    countries=deserialize(joinpath(root,"countries.jls"))
    fit=joinpath(root,"fit")
    baseline=deserialize(joinpath(fit,"baseline.jls"));seed=deserialize(joinpath(fit,"candidate.jls"))
    rows=CSV.read(joinpath(fit,"metrics.csv"),DataFrame)
    (;settings,borders,border_factors)=CE.saved_case(fit,countries;root)
    order=sortperm(length.(getproperty.(countries,:b)));completed=nrow(rows)-1
    0<completed<length(countries) || error("Expected an incomplete first sweep")
    rows.updated_country[2:end]==[countries[k].code for k in order[1:completed]] || error("Update order differs")
    edges=CE.graph(countries;borders)
    current=CE.metrics(countries,seed,edges)
    for key in keys(current)
        isapprox(getproperty(current,key),rows[end,key];rtol=1e-9,atol=1e-8) || error("Checkpoint differs from last metrics: $key")
    end
    weights=CE.edge_weights(edges,settings[:border_share])
    weights .*= [k==l ? settings[:internal_scale] : settings[:border_scale]*get(border_factors,minmax(countries[k].code,countries[l].code),1.) for (k,j,l,t) in edges]
    _,g=CE.penalty_gradient(countries,seed,edges;weights,scale_km=settings[:scale_km],form=settings[:form],internal_form=settings[:internal_form],saturating=settings[:saturating],forces_only=true)
    _,fg=CE.fold_penalty_gradient(countries,seed,CE.triangles(countries);smoothing_area=settings[:fold_smoothing],forces_only=true)
    forces=[settings[:strength].*a.+settings[:fold_strength].*b for (a,b) in zip(g,fg)]
    return (;countries,baseline,seed,rows,settings,borders,border_factors,order,completed,edges,weights,forces)
end

function inspect(root,out)
    ispath(out) && error("Output exists")
    state=interrupted_state(root);k=state.order[state.completed+1];c=state.countries[k];force=state.forces[k]
    mkpath(out)
    report=Dict("completed_updates"=>state.completed,"next_group_code"=>c.code,"sources"=>length(c.a),"targets"=>length(c.b),"force_min"=>minimum(force),"force_max"=>maximum(force),"force_max_abs"=>maximum(abs,force),"force_max_target"=>argmax(vec(sum(abs2,force;dims=1))),"eta"=>state.settings[:country_etas][c.code],"proximal"=>state.settings[:proximal],"dense_cost_bytes"=>4length(c.a)*length(c.b),"input_sha256"=>Dict(name=>bytes2hex(open(sha256,joinpath(root,"fit",name))) for name in ["candidate.jls","baseline.jls","metrics.csv","settings.csv"]),"checkpoint_matches_metrics"=>true)
    open(io->JSON.print(io,report,2),joinpath(out,"inspection.json"),"w")
    println(JSON.json(report));flush(stdout)
    return state
end

function pilot(root,out,proximal)
    state=inspect(root,out)
    oneAPI.functional() || error("oneAPI unavailable")
    (;countries,seed,settings,edges,weights)=state
    k=state.order[state.completed+1];c=countries[k]
    eta=settings[:country_etas][c.code]
    result=CE.compact_solve(c,state.forces[k],seed[k],oneAPI.oneAPIBackend();eta,proximal,
        tolerance=settings[:inner_tolerance],cache_bytes=2*1024^3,retry_factor=256,
        retry_after=200,maxiters=2000,
        stage_callback=(factor,result)->begin
            CE.checkpoint(joinpath(out,"stage-$factor.jls"),result)
            println("Saved checked stage $factor");flush(stdout)
        end)
    CE.checkpoint(joinpath(out,"proposal.jls"),result)
    temperatures=[settings[:country_etas][c.code] for c in countries]
    faces=CE.triangles(countries);base_cache=Dict()
    score(plans)=CE.objective(countries,plans,edges,settings[:strength],temperatures;
        base_cache,weights,scale_km=settings[:scale_km],form=settings[:form],internal_form=settings[:internal_form],saturating=settings[:saturating])+
        settings[:fold_strength]*first(CE.fold_penalty_gradient(countries,plans,faces;smoothing_area=settings[:fold_smoothing],forces_only=true))
    before=score(seed)
    isapprox(before,state.rows[end,:objective];rtol=1e-9) || error("Objective differs from checkpoint")
    reference=CE.metrics(countries,state.baseline,edges);trials=NamedTuple[]
    for damping in (settings[:max_damping]*2.0^-j for j in 0:9)
        plans=copy(seed);plans[k]=CE.mix_plans(seed[k],result.plan,damping)
        value=score(plans);m=CE.metrics(countries,plans,edges)
        accepted=value<before-1e-10 && m.spread_mean<=settings[:spread_limit]*reference.spread_mean &&
            m.spread_p90<=settings[:spread_limit]*reference.spread_p90 && m.interior_p90<=settings[:interior_limit]*reference.interior_p90 &&
            m.interior_max<=settings[:interior_limit]*reference.interior_max
        push!(trials,(;damping,accepted,objective=value,m...))
        if accepted
            CE.checkpoint(joinpath(out,"accepted.jls"),(;plans,beta=result.beta,updated_country=c.code,proximal,damping,objective=value,metrics=m))
            break
        end
    end
    CSV.write(joinpath(out,"trials.csv"),DataFrame(trials))
    println(last(trials));flush(stdout)
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS) in (2,3) || error("Usage: recover_h3_borders.jl FAILED_FIT NEW_OUTPUT [PILOT_PROXIMAL]")
    length(ARGS)==2 ? inspect(ARGS...) : pilot(ARGS[1],ARGS[2],parse(Float64,ARGS[3]))
end
