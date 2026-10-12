using Serialization
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame, norm
const CE=ContinuityExperiment

length(ARGS)>=8 || error("usage: compare_compact.jl SOURCES RES FACTOR DENSE_FIT COMPACT_FIT NEW_OUT CODES...")
input=ARGS[1];resolution=parse(Int,ARGS[2]);factor=parse(Int,ARGS[3])
densepath,compactpath,out=ARGS[4:6];codes=parse.(Int,ARGS[7:end])
ispath(out) && error("refusing to overwrite $out")
mkpath(out)
countries=[CE.country(joinpath(input,"country-$code-res$resolution.arrow"),code;factor,dense=false) for code in codes]
a=CE.saved_case(densepath,countries);b=CE.saved_case(compactpath,countries)
a.borders==b.borders && a.border_factors==b.border_factors || error("border settings differ")
for key in keys(a.settings)
    key in (:compact,:compact_cache_bytes,:checkpoint_interval) && continue
    isequal(a.settings[key],b.settings[key]) || error("settings differ: $key")
end
edges=CE.graph(countries;borders=a.borders)
rows=NamedTuple[]
for phase in ("baseline","candidate")
    dense=deserialize(joinpath(densepath,"$phase.jls"))
    compact=deserialize(joinpath(compactpath,"$phase.jls"))
    for (c,p,q) in zip(countries,dense,compact)
        q isa CE.CompactPlan || error("expected a compact checkpoint")
        CE.compact_stats!(q,c) # Recalculate; do not trust saved moments or masses.
        max_source_error=maximum(maximum(abs.(vec(sum(plan;dims=2))./c.a.-1)) for plan in (p,q))
        max_source_error<=1e-8 || error("source mass check failed")
        for plan in (p,q)
            mass=vec(sum(plan;dims=1))
            sum(abs.(mass.-c.b))<=a.settings[:inner_tolerance]+1e-10 || error("target L1 check failed")
            maximum(abs.(mass./c.b.-1))<=.001+1e-10 || error("target relative check failed")
        end
        l1=max_error=0.
        block=max(1,div(1_000_000,length(c.b)))
        for firstrow in 1:block:length(c.a)
            indices=firstrow:min(length(c.a),firstrow+block-1)
            delta=abs.(exp.(CE.logblock(q,indices)).-view(p,indices,:))
            l1+=sum(delta);max_error=max(max_error,maximum(delta))
        end
        u,v=CE.means(c,p),CE.means(c,q)
        u./=sqrt.(sum(abs2,u;dims=1));v./=sqrt.(sum(abs2,v;dims=1))
        shifts=[6371norm(u[:,j]-v[:,j]) for j in axes(u,2)]
        push!(rows,(;phase,code=c.code,plan_l1=l1,plan_max_absolute=max_error,
            centre_max_chord_km=maximum(shifts),source_max_relative=max_source_error,
            dense_bytes=Base.summarysize(p),compact_bytes=Base.summarysize(q)))
    end
    CSV.write(joinpath(out,"$phase-metrics.csv"),DataFrame([
        (;mode="dense",CE.metrics(countries,dense,edges)...),
        (;mode="compact",CE.metrics(countries,compact,edges)...)]))
    for (mode,plans) in (("dense",dense),("compact",compact))
        CSV.write(joinpath(out,"$phase-$mode-orientation.csv"),ContinuityDiagnostics.orientations(countries,plans))
    end
end
CSV.write(joinpath(out,"comparison.csv"),DataFrame(rows))
println("Mass checks passed; comparison written to $out")
