using Serialization, Dates, oneAPI
include("experiment.jl")
include("diagnostics.jl")
const CE=ContinuityExperiment
using .ContinuityExperiment: CSV, DataFrame

function refinement_target(target,factor::Int)
    factor>=2 || error("refinement factor must be at least two")
    allunique(zip(target.x,target.y)) || error("duplicate coarse targets")
    DataFrame([(x=factor*r.x+2ix-factor-1,y=factor*r.y+2iy-factor-1,parent_cell_id=j)
        for (j,r) in enumerate(eachrow(target)) for ix in 1:factor for iy in 1:factor])
end

function refinement_cuts(c,factor)
    Set((factor*x+2ix-factor-1,factor*y+2iy-factor-1)
        for (x,y) in get(c,:cut_targets,Set{Tuple{Float64,Float64}}())
        for ix in 1:factor for iy in 1:factor)
end

function refinement_settings(settings,factor;outer_steps=4)
    factor>=2 && outer_steps>0 || error("invalid refinement limits")
    result=Dict{Symbol,Any}(settings)
    # Eta is selected on the fine grid below, not inherited from the coarse fit.
    pop!(result,:country_etas,nothing)
    result[:eta]/=factor^2
    result[:internal_scale]=get(settings,:internal_scale,1.)*factor^2
    result[:border_scale]=get(settings,:border_scale,1.)*factor
    result[:fold_strength]=get(settings,:fold_strength,0.)*factor^2
    result[:fold_smoothing]=get(settings,:fold_smoothing,0.)/factor^2
    merge!(result,Dict(:outer_steps=>outer_steps,:start_step=>1,:compact=>true,
        :matrix_free=>false,:anneal=>false,:save_passes=>true))
end

function fit_refined(coarse,coarse_plans,countries,backend,out;factor,settings,
                     borders,border_factors=Dict(),outer_steps=4,etas=CE.PCP.ETA_CANDIDATES,
                     provenance="")
    ispath(out) && error("refusing to overwrite $out")
    length(coarse)==length(coarse_plans)==length(countries)>0 || error("country counts differ")
    allunique(getproperty.(countries,:code)) || error("duplicate country codes")
    for (c,d) in zip(coarse,countries)
        c.code==d.code || error("country order differs")
        d.target==refinement_target(c.target,factor) || error("fine target grid differs")
        get(d,:cut_targets,Set())==refinement_cuts(c,factor) || error("fine cut mask differs")
    end
    settings=refinement_settings(settings,factor;outer_steps)
    solve_options=(;tolerance=get(settings,:inner_tolerance,1e-5),accelerate=get(settings,:accelerate,true),
        cache_bytes=get(settings,:compact_cache_bytes,512*1024^2),
        retry_factor=get(settings,:compact_retry_factor,16))
    mkpath(out)
    write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nRelative target factor: $factor\n" * provenance)
    CE.checkpoint(joinpath(out,"countries.jls"),countries)
    baseline=CE.CompactPlan[];seed=CE.CompactPlan[];selected=Dict{Int,Float64}()
    for (c,p,d) in zip(coarse,coarse_plans,countries)
        println("$(now(UTC)) Fine-grid calibration $(d.code)");flush(stdout)
        tuned=CE.compact_tune(d,backend;etas,solve_options...)
        CE.checkpoint(joinpath(out,"calibration-$(d.code).jls"),tuned)
        CSV.write(joinpath(out,"calibration-$(d.code).csv"),DataFrame(tuned.stages))
        tuned.support.rows<=1.25tuned.target_rows || error("fine baseline is too broad for $(d.code)")
        selected[d.code]=tuned.eta;push!(baseline,tuned.result.plan)
        p isa CE.CompactPlan && CE.compact_stats!(p,c)
        target=copy(c.target);target.parent_cell_id=collect(1:length(c.b))
        centres=CE.refined_centres(merge(c,(;target)),p,d)
        # A soft geographic guide supplies a balanced starting plan. It is not
        # a constraint or a force in the subsequent continuity objective.
        proposal=CE.compact_solve(d,-centres,nothing,backend;eta=tuned.eta,solve_options...)
        push!(seed,proposal.plan)
        GC.gc()
    end
    settings[:country_etas]=selected
    CE.checkpoint(joinpath(out,"baseline.jls"),baseline)
    CE.checkpoint(joinpath(out,"seed.jls"),seed)
    result=CE.run_case(countries,backend,joinpath(out,"fit");settings...,
        initial_plans=baseline,starting_plans=seed,borders,border_factors,export_arrow=false)
    plans=deserialize(joinpath(out,"fit","candidate.jls"))
    orientation=ContinuityDiagnostics.orientations(countries,plans)
    CSV.write(joinpath(out,"fit","candidate-orientation.csv"),orientation)
    CSV.write(joinpath(out,"summary.csv"),DataFrame([(;positive_triangles=sum(orientation.positive),
        positive_area_km2=sum(orientation.positive_area_km2),last(result)...)]))
    write(joinpath(out,"research-fit-complete.txt"),
        "Completed $(last(result).iteration) fine-grid passes at $(now(UTC)) UTC.\nNot published. Audit sharpness, borders, and orientation before use.\n")
    result
end

function refine_grid(input,trial,source_dir,out,resolution,factor;backend=oneAPI.oneAPIBackend(),kwargs...)
    ispath(out) && error("refusing to overwrite $out")
    coarse=deserialize(joinpath(input,"countries.jls"))
    coarse_plans=deserialize(joinpath(input,trial,"candidate.jls"))
    (;settings,borders,border_factors)=CE.saved_case(joinpath(input,trial),coarse;root=input)
    countries=[merge(CE.country(joinpath(source_dir,"country-$(c.code)-res$resolution.arrow"),c.code;
        target=refinement_target(c.target,factor),dense=false),(;cut_targets=refinement_cuts(c,factor))) for c in coarse]
    all(c->all(id->CE.H3.API.getResolution(id)==resolution,c.source.id),countries) || error("source resolution differs")
    provenance="Input: $(abspath(input))/$trial\nSources: $(abspath(source_dir))\nResolution: $resolution\n" * read(`git rev-parse HEAD`,String)
    fit_refined(coarse,coarse_plans,countries,backend,out;factor,settings,borders,border_factors,provenance,kwargs...)
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==6 || error("usage: refine_grid.jl COARSE_STUDY COARSE_TRIAL SOURCE_DIRECTORY NEW_OUTPUT RESOLUTION RELATIVE_FACTOR")
    oneAPI.functional() || error("oneAPI is not functional")
    refine_grid(ARGS[1:4]...,parse.(Int,ARGS[5:6])...;
        outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","4")))
end
