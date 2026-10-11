using Dates, Serialization, oneAPI
include("experiment.jl")
using .ContinuityExperiment: CSV, DataFrame

2 <= length(ARGS) <= 3 || error("usage: sweep.jl AFRICA_SOURCE_DIRECTORY OUTPUT_DIRECTORY [force|balanced]")
source_dir,outdir=abspath.(ARGS[1:2])
mode=length(ARGS)==3 ? ARGS[3] : "force"
mode in ("force","balanced") || error("unknown sweep mode")
ispath(outdir) && error("refusing to overwrite $outdir")
oneAPI.functional() || error("oneAPI is not functional")
mkpath(outdir)
backend=oneAPI.oneAPIBackend()
oneAPI.versioninfo()
println("Started: $(now())")
flush(stdout)
countries=[ContinuityExperiment.country(joinpath(source_dir,"country-$code-res4.arrow"),code)
           for code in (24,180,894)]
borders=Set([(24,180),(24,894),(180,894)])
base=[ContinuityExperiment.sinkhorn(c.cost,c.a,c.b,backend).plan for c in countries]
serialize(joinpath(outdir,"countries.jls"),countries)
serialize(joinpath(outdir,"baseline.jls"),base)
rows=NamedTuple[]
configs = mode=="force" ?
    [(;form,saturating,strength,border_share=.95,preserve_displacements=false,interior_limit=1.25)
     for form in (:distribution,:mean), saturating in (false,true), strength in (.01,.1,1.0)] :
    [(;form=:distribution,saturating=false,strength,border_share,preserve_displacements,interior_limit=2.0)
     for border_share in (.1,.25,.5), strength in (.1,1.0), preserve_displacements in (false,true)]
for cfg in configs
    (;form,saturating,strength,border_share,preserve_displacements,interior_limit)=cfg
    name="$(form)-$(saturating ? "saturating" : "quadratic")-$strength-border$border_share-displacement$preserve_displacements"
    path=joinpath(outdir,name)
    println("$(now()) Trial: $name")
    flush(stdout)
    start=time()
    try
        result=ContinuityExperiment.run_case(countries,backend,path;
            borders,border_share,form,saturating,strength,scale_km=900.0,preserve_displacements,
            interior_limit,spread_limit=1.25,outer_steps=mode=="force" ? 20 : 40,
            initial_plans=base,export_arrow=false)
        r=last(result)
        push!(rows,(;name,seconds=time()-start,accepted_steps=count(x->x.accepted,result)-1,
                    ratio50=r.seam_p50/max(r.local_p50,1e-9),
                    ratio90=r.seam_p90/max(r.local_p90,1e-9),
                    distribution_ratio50=r.cross_rms_p50/max(r.local_rms_p50,1e-9),
                    distribution_ratio90=r.cross_rms_p90/max(r.local_rms_p90,1e-9),
                    r...))
        CSV.write(joinpath(outdir,"summary.csv"),DataFrame(rows))
    catch e
        open(joinpath(outdir,"failures.log"),"a") do io
            println(io,"$(now()) $name: ",sprint(showerror,e,catch_backtrace()))
        end
        println("FAILED $name: ",sprint(showerror,e))
    end
    flush(stdout)
    GC.gc()
end
println("Completed: $(now())")
