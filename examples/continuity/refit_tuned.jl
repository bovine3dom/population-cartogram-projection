# Refit borders from a complete, checked compact baseline calibration.
using Serialization, Dates, SHA, oneAPI
include("experiment.jl")
const CE=ContinuityExperiment
using .CE: CSV,DataFrame

function refit_tuned(input,tuned,out;backend=oneAPI.oneAPIBackend(),outer_steps=4,proximal=.01,retry_factor=256)
    outer_steps>0 && isfinite(proximal) && proximal>=0 && ispow2(retry_factor) || error("invalid fit limits")
    ispath(out) && error("output exists")
    isfile(joinpath(tuned,"tuning-complete.txt")) || error("calibration is incomplete")
    countries=deserialize(joinpath(input,"countries.jls"))
    selection=CSV.read(joinpath(tuned,"selection.csv"),DataFrame)
    allunique(selection.code) && Set(selection.code)==Set(getproperty.(countries,:code)) || error("calibration countries differ")
    angles=Dict(r.code=>r.angle for r in eachrow(selection))
    seed=CE.CompactPlan[];duals=Vector{Float64}[];etas=Dict{Int,Float64}();reports=NamedTuple[]
    for c in countries
        path=joinpath(tuned,string(c.code),"selected.jls");entry=deserialize(path)
        budget=2(length(c.a)+length(c.b))
        # The nearest-budget candidate can lie just above the allowed limit.
        if entry.support.rows>1.25budget
            eligible=filter(r->r.converged && r.rows<=1.25budget,entry.stages)
            isempty(eligible) && error("no sharp checked stage for $(c.code)")
            stage=eligible[argmin([abs(r.rows-budget) for r in eligible])]
            path=joinpath(tuned,string(c.code),"eta-$(stage.eta).jls")
            entry=merge(entry,(;eta=stage.eta,result=deserialize(path)))
        end
        p=entry.result.plan
        length(p.data.keep)==1 && only(p.data.rho)==0 && all(iszero,p.data.force) || error("not a pure baseline")
        isapprox(inv(only(p.data.inverse_eta)),entry.eta;rtol=1e-12) || error("baseline eta differs")
        expected=CE.pose_problem(c,angles[c.code]);actual=p.problems[only(p.data.base_id)]
        all(getfield(expected,key)==getfield(actual,key) for key in fieldnames(typeof(expected))) || error("baseline geometry differs")
        p.data.geo==c.xyz.-CE.mean(c.xyz;dims=2) || error("source geography differs")
        CE.compact_stats!(p,c)
        source_error=maximum(abs.(p.stats.source./c.a.-1))
        target_error=sum(abs.(p.stats.target.-c.b));relative=maximum(abs.(p.stats.target./c.b.-1))
        source_error<=1e-8 && target_error<=1e-4 && relative<=.001 || error("baseline mass check failed")
        support=CE.ContinuitySharpness.retained_support(p,(p,r)->exp.(CE.logblock(p,r)))
        support.rows<=1.25budget || error("baseline is too broad")
        push!(reports,(;code=c.code,angle=angles[c.code],eta=entry.eta,rows=support.rows,target_rows=budget,
            source_error,target_error,target_relative=relative,sha256=bytes2hex(open(sha256,path))))
        push!(seed,p);push!(duals,Float64.(entry.result.beta));etas[c.code]=entry.eta
        println(now(UTC)," checked baseline ",c.code);flush(stdout)
    end
    (;settings,borders,border_factors)=CE.saved_case(joinpath(input,"fit"),countries;root=input)
    merge!(settings,Dict(:country_etas=>etas,:start_step=>1,:max_damping=>1.,:save_passes=>true,
        :compact=>true,:compact_retry_factor=>retry_factor,:proximal=>proximal,:outer_steps=>outer_steps))
    mkpath(out);CE.checkpoint(joinpath(out,"countries.jls"),countries)
    CSV.write(joinpath(out,"selection.csv"),DataFrame(reports))
    write(joinpath(out,"provenance.txt"),"Started: $(now(UTC)) UTC\nParent: $(abspath(input))\nCalibration: $(abspath(tuned))\n"*read(`git rev-parse HEAD`,String))
    result=CE.run_case(countries,backend,joinpath(out,"fit");settings...,initial_plans=seed,
        initial_duals=duals,borders,border_factors,export_arrow=false)
    write(joinpath(out,"research-fit-complete.txt"),"Completed $(last(result).iteration) passes: $(now(UTC)) UTC\nNot published. Audit sharpness and geometry before use.\n")
    return result
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==3 || error("usage: refit_tuned.jl PARENT_ROOT CALIBRATION_ROOT NEW_OUTPUT")
    oneAPI.functional() || error("oneAPI is unavailable")
    refit_tuned(ARGS...;outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","4")),
        proximal=parse(Float64,get(ENV,"CONTINUITY_PROXIMAL",".01")),
        retry_factor=parse(Int,get(ENV,"CONTINUITY_RETRY_FACTOR","256")))
end
