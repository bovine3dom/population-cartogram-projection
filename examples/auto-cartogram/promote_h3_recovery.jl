#!/usr/bin/env julia
# Build a new checkpoint only after validating an accepted recovery proposal.
include("recover_h3_borders.jl")

function plan_digest(plan)
    io=IOBuffer();serialize(io,plan);bytes2hex(sha256(take!(io)))
end

function promote(root,pilot_dir,out)
    ispath(out) && error("Output exists")
    state=interrupted_state(root)
    inspection=JSON.parsefile(joinpath(pilot_dir,"inspection.json"))
    for (name,hash) in inspection["input_sha256"]
        bytes2hex(open(sha256,joinpath(root,"fit",name)))==hash || error("Pilot inputs changed")
    end
    accepted=deserialize(joinpath(pilot_dir,"accepted.jls"))
    k=state.order[state.completed+1]
    accepted.updated_country==state.countries[k].code || error("Wrong recovered group")
    length(accepted.plans)==length(state.seed) || error("Group coverage changed")
    for i in eachindex(state.seed)
        i==k || plan_digest(state.seed[i])==plan_digest(accepted.plans[i]) || error("An earlier group changed")
        p=accepted.plans[i];c=state.countries[i]
        CE.valid_plan(p) && maximum(abs.(vec(sum(p;dims=2))./c.a.-1))<=1e-8 || error("Invalid source masses")
    end
    m=CE.metrics(state.countries,accepted.plans,state.edges)
    for key in keys(m)
        isapprox(getproperty(m,key),getproperty(accepted.metrics,key);rtol=1e-9,atol=1e-8) || error("Pilot metrics differ")
    end
    m.marginal_error<=state.settings[:inner_tolerance] && m.target_max_relative<=.001 || error("Target mass check failed")
    # Recheck the original objective, independent of the proposal's proximal weight.
    temperatures=[state.settings[:country_etas][c.code] for c in state.countries]
    value=CE.objective(state.countries,accepted.plans,state.edges,state.settings[:strength],temperatures;
        weights=state.weights,scale_km=state.settings[:scale_km],form=state.settings[:form],internal_form=state.settings[:internal_form],saturating=state.settings[:saturating])+
        state.settings[:fold_strength]*first(CE.fold_penalty_gradient(state.countries,accepted.plans,CE.triangles(state.countries);smoothing_area=state.settings[:fold_smoothing],forces_only=true))
    isapprox(value,accepted.objective;rtol=1e-9) && value<state.rows[end,:objective]-1e-10 || error("Objective did not improve")
    reference=CE.metrics(state.countries,state.baseline,state.edges)
    all(getproperty(m,key)<=state.settings[limit]*getproperty(reference,key) for (key,limit) in
        [(:spread_mean,:spread_limit),(:spread_p90,:spread_limit),(:interior_p90,:interior_limit),(:interior_max,:interior_limit)]) || error("Distortion guard failed")
    mkpath(joinpath(out,"fit"))
    cp(joinpath(root,"countries.jls"),joinpath(out,"countries.jls"))
    for name in ("baseline.jls","borders.csv","border-factors.csv","country-etas.csv","settings.csv")
        cp(joinpath(root,"fit",name),joinpath(out,"fit",name))
    end
    settings=CSV.read(joinpath(out,"fit","settings.csv"),DataFrame)
    settings.proximal .= accepted.proximal
    settings.compact_cache_bytes .= 2*1024^3
    CSV.write(joinpath(out,"fit","settings.csv"),settings)
    CE.checkpoint(joinpath(out,"fit","candidate.jls"),accepted.plans)
    rows=copy(state.rows)
    push!(rows,(;iteration=1,updated_country=accepted.updated_country,damping=accepted.damping,accepted=true,objective=value,m...))
    CSV.write(joinpath(out,"fit","metrics.csv"),rows)
    provenance=Dict("parent"=>abspath(root),"pilot"=>abspath(pilot_dir),"completed_updates"=>nrow(rows)-1,
        "recovered_group"=>accepted.updated_country,"proximal"=>accepted.proximal,"unchanged_other_groups"=>true,
        "settings_scope"=>"New proximal weight and cache apply to recovery updates, not the copied prefix.",
        "files"=>Dict(abspath(p)=>bytes2hex(open(sha256,p)) for p in [@__FILE__,joinpath(pilot_dir,"accepted.jls"),joinpath(pilot_dir,"inspection.json")]))
    open(io->JSON.print(io,provenance,2),joinpath(out,"recovery.json"),"w")
    if nrow(rows)-1==length(state.countries)
        CE.checkpoint(joinpath(out,"fit","pass-1.jls"),(;iteration=1,step=length(state.countries),start_step=1,plans=accepted.plans,metrics=[NamedTuple(r) for r in eachrow(rows)]))
        write(joinpath(out,"research-fit-complete.txt"),"Complete first sweep; recovered updates pass the original objective, mass, and distortion checks. Export audit still required.\n")
    end
    println("Saved verified checkpoint with $(nrow(rows)-1) completed updates")
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==3 || error("Usage: promote_h3_recovery.jl FAILED_FIT ACCEPTED_PILOT NEW_CHECKPOINT")
    promote(ARGS...)
end
