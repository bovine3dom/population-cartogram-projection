using Dates, Serialization, oneAPI
include("experiment.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==2 || error("usage: sweep.jl AFRICA_SOURCE_DIRECTORY OUTPUT_DIRECTORY")
source_dir,outdir=abspath.(ARGS)
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
# Stronger border forces, with explicit relaxation of the original 5% safeguards.
for form in (:distribution,:mean), saturating in (false,true), strength in (.01,.1,1.0)
    name="$(form)-$(saturating ? "saturating" : "quadratic")-$strength"
    path=joinpath(outdir,name)
    println("$(now()) Trial: $name")
    flush(stdout)
    start=time()
    try
        result=ContinuityExperiment.run_case(countries,backend,path;
            borders,border_share=.95,form,saturating,strength,scale_km=900.0,
            interior_limit=1.25,spread_limit=1.25,outer_steps=20,
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
