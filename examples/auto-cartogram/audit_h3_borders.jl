#!/usr/bin/env julia
# Check the final sparse island mapping after extraction and population balance.
using SparseArrays
include("border_h3_groups.jl")

function sparse_plans(root,countries,codes)
    map(countries) do c
        group=codes[c.code]
        source=Dict(id=>i for (i,id) in enumerate(c.source.id))
        target=Dict((div(r.x,2),div(-r.y,2))=>j for (j,r) in enumerate(eachrow(c.target)))
        d=CSV.read(joinpath(root,"balanced",group,"mapping.csv"),DataFrame)
        allunique(zip(d.id,d.x,d.y)) || error("Duplicate fragment/target pair")
        i=[source[id] for id in d.id];j=[target[(x,y)] for (x,y) in zip(d.x,d.y)]
        p=sparse(i,j,d.weight.*c.a[i],length(c.a),length(c.b))
        maximum(abs.(vec(sum(p;dims=2))./c.a.-1))<=1e-9 || error("Source mass differs")
        maximum(abs.(vec(sum(p;dims=1))./c.b.-1))<=1.00001e-4 || error("Target mass differs")
        p
    end
end

function audit_groups(original,out,fit)
    reportpath=joinpath(out,"border-audit.json");ispath(reportpath) && error("Audit exists")
    countries=deserialize(joinpath(out,"countries.jls"));borders=deserialize(joinpath(out,"borders.jls"))
    codes=Dict(r.code=>String(r.group_id) for r in eachrow(CSV.read(joinpath(out,"group-codes.csv"),DataFrame)))
    edges=CE.graph(countries;borders)
    before=sparse_plans(original,countries,codes);after=sparse_plans(out,countries,codes)
    baseline=deserialize(joinpath(fit,"fit","baseline.jls"))
    results=Dict{String,Any}()
    for (name,plans) in [("original",before),("tuned_baseline",baseline),("border_export",after)]
        metrics=CE.metrics(countries,plans,edges)
        moments=(c,p)->p isa CE.CompactPlan ? p.stats.moment : c.xyz*p
        orientation=ContinuityDiagnostics.orientations(countries,plans;moments)
        CSV.write(joinpath(out,name*"-orientation.csv"),orientation)
        CE.export_seams(joinpath(out,name*"-seams.csv"),countries,plans,edges)
        results[name]=Dict("metrics"=>Dict(string(k)=>v for (k,v) in pairs(metrics)),"reversed_triangle_area_km2"=>sum(orientation.positive_area_km2))
    end
    b=results["tuned_baseline"]["metrics"];a=results["border_export"]["metrics"]
    results["numerical_gate"]=a["cross_rms_all"]<b["cross_rms_all"] &&
        a["spread_mean"]<=1.251b["spread_mean"] && a["spread_p90"]<=1.251b["spread_p90"] &&
        a["interior_p90"]<=4.001b["interior_p90"] && a["interior_max"]<=4.001b["interior_max"]
    results["limit"]="A numerical gate is not visual approval. Inspect folds, source spread, city positions, and all saved seam pairs. Layout coordinates and island population eligibility remain fixed."
    results["files"]=Dict(abspath(p)=>bytes2hex(open(sha256,p)) for p in [@__FILE__,joinpath(fit,"fit","candidate.jls"),joinpath(out,"balance-complete.json")])
    open(io->JSON.print(io,results,2),reportpath,"w")
    results["numerical_gate"] || error("Final border export failed numerical comparison; do not publish")
    println("Border RMS: ",b["cross_rms_all"]," -> ",a["cross_rms_all"]," km")
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==3 || error("Usage: audit_h3_borders.jl ORIGINAL OUTPUT FIT")
    audit_groups(ARGS...)
end
