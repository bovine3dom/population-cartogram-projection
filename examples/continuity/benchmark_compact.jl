using oneAPI, Dates, Serialization
include("experiment.jl")
using .ContinuityExperiment: CSV, DataFrame
const CE=ContinuityExperiment

length(ARGS)>=8 || error("usage: benchmark_compact.jl SOURCES RES FACTOR dense|compact PASSES NEW_OUT CODES...")
input=ARGS[1];resolution=parse(Int,ARGS[2]);factor=parse(Int,ARGS[3]);mode=ARGS[4]
steps=parse(Int,ARGS[5]);out=ARGS[6];codes=parse.(Int,ARGS[7:end])
mode in ("dense","compact") || error("unknown mode")
ispath(out) && error("refusing to overwrite $out")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(out)
compact=mode=="compact"
backend=oneAPI.oneAPIBackend()
write(joinpath(out,"provenance.txt"),"$(now(UTC)) UTC\n"*read(`git rev-parse HEAD`,String))
println("$(now(UTC)) prepare $codes factor=$factor mode=$mode");flush(stdout)
preparation=@timed countries=[CE.country(joinpath(input,"country-$code-res$resolution.arrow"),code;factor,dense=!compact) for code in codes]
borders=Set(minmax(a,b) for a in codes for b in codes if a!=b)
println("$(now(UTC)) fit");flush(stdout)
measured=@timed rows=CE.run_case(countries,backend,joinpath(out,"fit");compact,borders,
    strength=10.,eta=.002,border_share=.25,scale_km=900.,form=:distribution,saturating=false,
    fold_strength=1.,proximal=.1,coordinate=true,outer_steps=steps,spread_limit=1.25,interior_limit=4.,
    inner_tolerance=1e-4,accelerate=true,export_arrow=false,checkpoint_interval=length(countries))
plans=deserialize(joinpath(out,"fit","candidate.jls"))
CSV.write(joinpath(out,"summary.csv"),DataFrame([(;mode,resolution,factor,steps,
    prepare_seconds=preparation.time,fit_seconds=measured.time,allocated_bytes=measured.bytes,
    country_bytes=Base.summarysize(countries),plan_bytes=Base.summarysize(plans),
    pairs=sum(length(c.a)*length(c.b) for c in countries),last(rows)...)]))
println("$(now(UTC)) completed fit_seconds=$(measured.time) plan_bytes=$(Base.summarysize(plans))")
