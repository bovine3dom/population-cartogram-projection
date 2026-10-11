using Dates, Serialization, SHA, oneAPI
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame, nrow

length(ARGS)==6 || error("usage: study.jl SOURCE_DIRECTORY OUTPUT_DIRECTORY GROUP RESOLUTION FACTOR fold|validate")
source_dir,outdir=abspath.(ARGS[1:2])
group=ARGS[3]; resolution=parse(Int,ARGS[4]); factor=parse(Int,ARGS[5]); mode=ARGS[6]
groups=Dict("africa"=>[24,180,894],"mali-burkina"=>[466,854],"germany-poland"=>[276,616])
haskey(groups,group) || error("unknown study group")
mode in ("fold","validate") || error("unknown study mode")
deadline=DateTime(get(ENV,"CONTINUITY_DEADLINE","9999-12-31T23:59:59"))
selected=Set(filter(!isempty,split(get(ENV,"CONTINUITY_CASES",factor>1 ? "border0.25-fold0.01" : ""),',')))
outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","30"))
outer_steps>0 || error("outer steps must be positive")
ispath(outdir) && error("refusing to overwrite $outdir")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(outdir)
codes=groups[group]
borders=Set(minmax(codes[i],codes[j]) for i in eachindex(codes) for j in i+1:length(codes))
backend=oneAPI.oneAPIBackend()
println("Started: $(now(UTC)); group=$group resolution=$resolution factor=$factor")
oneAPI.versioninfo(); flush(stdout)
countries=[ContinuityExperiment.country(joinpath(source_dir,"country-$code-res$resolution.arrow"),code;factor) for code in codes]
ContinuityExperiment.checkpoint(joinpath(outdir,"countries.jls"),countries)
configs=[(;border_share,fold_strength,eta=.002/factor^2) for border_share in (.1,.25),
         fold_strength in (mode=="fold" ? (0.,.01,.1) : (0.,.01))]
rows=NamedTuple[]
base_cache=Dict{Float64,Any}()
root=normpath(joinpath(@__DIR__,"..",".."))
report=joinpath(root,"benchmark","continuity-runs",basename(outdir)*".csv")
log_path=joinpath(root,"benchmark","continuity-runs",basename(outdir)*".md")
mkpath(dirname(report))
ispath(report) && error("report already exists")
open(log_path,"w") do io
    println(io,"# Continuity study: $(basename(outdir))\n\nStarted: $(now(UTC)) UTC.")
    println(io,"\nGroup: $group. H3 resolution: $resolution. Subdivision factor: $factor.")
    println(io,"\nThe CSV contains measurements, not a production acceptance decision.")
end
open(joinpath(outdir,"provenance.txt"),"w") do io
    println(io,"Started: $(now(UTC)) UTC\n",read(`git -C $root rev-parse HEAD`,String))
    for path in [joinpath(@__DIR__,"experiment.jl"),@__FILE__,
                 [joinpath(source_dir,"country-$code-res$resolution.arrow") for code in codes]...]
        println(io,bytes2hex(open(sha256,path)),"  ",path)
    end
end
for cfg in configs
    now(UTC)>=deadline && break
    (;border_share,fold_strength,eta)=cfg
    name="border$border_share-fold$fold_strength"
    isempty(selected) || name in selected || continue
    path=joinpath(outdir,name)
    started=time()
    println("$(now(UTC)) Trial: $name"); flush(stdout)
    try
        base=get!(base_cache,eta) do
            [ContinuityExperiment.feature_sinkhorn(c,zeros(3,length(c.b)),backend;eta,tolerance=1e-4,anneal=factor>1,accelerate=factor>1).plan for c in countries]
        end
        result=ContinuityExperiment.run_case(countries,backend,path;
            borders,border_share,fold_strength=fold_strength*factor^2,eta,strength=1.0,form=:distribution,saturating=false,
            scale_km=900.,interior_limit=2.,spread_limit=1.25,outer_steps,
            initial_plans=base,export_arrow=false,matrix_free=true,internal_scale=factor^2,inner_tolerance=1e-4,anneal=factor>1,accelerate=factor>1)
        plans=deserialize(joinpath(path,"candidate.jls"))
        orientation=ContinuityDiagnostics.orientations(countries,plans)
        CSV.write(joinpath(path,"candidate-orientation.csv"),orientation)
        CSV.write(joinpath(path,"baseline-orientation.csv"),ContinuityDiagnostics.orientations(countries,base))
        r=last(result); b=first(result)
        push!(rows,(;name,seconds=time()-started,positive_triangles=sum(orientation.positive),
            baseline_local_p50=b.local_p50,baseline_local_rms_p50=b.local_rms_p50,
            baseline_seam_p50=b.seam_p50,baseline_cross_rms_p50=b.cross_rms_p50,
            ratio_to_original_local=r.seam_p50/max(b.local_p50,1e-9),
            ratio_to_current_local=r.seam_p50/max(r.local_p50,1e-9),r...))
        CSV.write(joinpath(outdir,"summary.csv"),DataFrame(rows))
        CSV.write(report,DataFrame(rows))
        open(log_path,"a") do io
            println(io,"\n## $(now(UTC)) UTC — $name\n\nCompleted in $(round(time()-started;digits=1)) seconds.")
            println(io,"\nBorder median: $(round(r.seam_p50;digits=1)) km. Local internal median: $(round(r.local_p50;digits=1)) km.")
            println(io,"\nPositive-area triangles: $(sum(orientation.positive)). See the CSV and per-pair outputs before selecting this result.")
        end
    catch e
        message=sprint(showerror,e,catch_backtrace())
        open(joinpath(outdir,"failures.log"),"a") do io
            println(io,"$(now(UTC)) $name: $message")
        end
        open(log_path,"a") do io
            println(io,"\n## $(now(UTC)) UTC — $name\n\nThe trial failed. See `failures.log` in the output directory.")
        end
        println("FAILED $name: ",sprint(showerror,e))
    end
    flush(stdout)
    if get(ENV,"CONTINUITY_COMMIT_REPORTS","")=="1"
        files=isfile(report) ? [report,log_path] : [log_path]
        run(`git -C $root add -- $files`)
        run(`git -C $root diff --cached --stat`)
        run(`git -C $root commit --only -m $("Record continuity study "*basename(outdir)*": "*name) -- $files`)
    end
    GC.gc()
end
println("Completed: $(now(UTC))")
