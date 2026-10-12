# Fitting helpers for planet.jl. Preparation and publication stay in that script.
function planet_compact_solve(c,backend,cache_bytes)
    force=zeros(3,length(c.b))
    try
        return CE.compact_sinkhorn(c,force,nothing,backend;eta=.002,tolerance=1e-4,cache_bytes)
    catch err
        err isa CE.CompactConvergenceError || rethrow()
        println("$(now(UTC)) temperature retry country=$(c.code): $err");flush(stdout)
    end
    # Sharply separated coarse populations can converge very slowly at fixed eta.
    beta=nothing;result=nothing
    for factor in (16.,8.,4.,2.,1.)
        result=CE.compact_sinkhorn(c,force,nothing,backend;eta=.002factor,tolerance=1e-4,cache_bytes,initial_beta=beta)
        beta=result.beta
        println("$(now(UTC)) temperature factor=$factor iterations=$(result.iterations) residual=$(result.marginal_error)");flush(stdout)
        GC.gc()
    end
    return result
end

function planet_baseline(countries,backend,out;compact,cache_bytes=512*1024^2)
    cache=joinpath(out,"baseline-cache");mkpath(cache)
    plans=compact ? Vector{CE.CompactPlan}(undef,length(countries)) : Vector{Matrix{Float64}}(undef,length(countries))
    for k in sortperm(length.(getproperty.(countries,:b)))
        c=countries[k];path=joinpath(cache,"$(c.code).jls")
        if isfile(path)
            plans[k]=deserialize(path)
        else
            println("$(now(UTC)) baseline country=$(c.code) sources=$(length(c.a)) targets=$(length(c.b)) compact=$compact");flush(stdout)
            result=compact ? planet_compact_solve(c,backend,cache_bytes) :
                CE.sinkhorn(c.cost,c.a,c.b,backend;eta=.002,tolerance=1e-4,accelerate=true)
            plans[k]=result.plan
            CE.checkpoint(path,result.plan)
            println("$(now(UTC)) baseline complete country=$(c.code) residual=$(result.marginal_error)");flush(stdout)
        end
        GC.gc()
    end
    return plans
end

function planet_poses(countries,baseline,borders,backend,out;compact,proposals=nothing,cache_bytes=512*1024^2)
    edges=CE.graph(countries;borders)
    factors=local_factors(countries,baseline,edges)
    weights=CE.edge_weights(edges,.25)
    for (i,(k,j,l,t)) in enumerate(edges)
        k==l || (weights[i]*=factors[minmax(countries[k].code,countries[l].code)])
    end
    strength=15.0length(countries);fold_strength=.5length(countries)
    faces=CE.triangles(countries);base_cache=Dict()
    score(p)=CE.objective(countries,p,edges,strength,.002;base_cache,weights,scale_km=900.,form=:distribution,saturating=false)+
        fold_strength*first(CE.fold_penalty_gradient(countries,p,faces;forces_only=true))
    reference=CE.metrics(countries,baseline,edges)
    within(m)=m.spread_mean<=1.25reference.spread_mean && m.spread_p90<=1.25reference.spread_p90 &&
        m.interior_p90<=4reference.interior_p90 && m.interior_max<=4reference.interior_max
    seed=copy(baseline);angles=Dict{Int,Int}()
    posecache=joinpath(out,"pose-cache");mkpath(posecache)
    rows=NamedTuple[]
    legacy=isfile(joinpath(out,"poses.csv")) ? CSV.read(joinpath(out,"poses.csv"),DataFrame) : DataFrame()
    for k in sortperm(length.(getproperty.(countries,:b)))
        c=countries[k];path=joinpath(posecache,"$(c.code).jls")
        if isfile(path)
            entry=deserialize(path)
            if entry isa AbstractMatrix
                # Read early dense checkpoints without changing their contents.
                row=only(filter(r->r.code==c.code,eachrow(legacy)))
                entry=(plan=entry,angle=row.angle,objective=row.objective)
            end
            seed[k]=entry.plan;angles[c.code]=entry.angle
            push!(rows,(;code=c.code,angle=entry.angle,objective=entry.objective))
            continue
        end
        best=score(seed);chosen=0
        candidates=isnothing(proposals) ? (45:45:315) : [proposals[c.code]]
        for angle in candidates
            angle==0 && continue
            println("$(now(UTC)) pose country=$(c.code) angle=$angle compact=$compact");flush(stdout)
            result=if compact
                # Change the solve geometry but retain the original objective cost.
                posed=merge(c,(;problem=CE.pose_problem(c,angle)))
                planet_compact_solve(posed,backend,cache_bytes)
            else
                CE.sinkhorn(CE.pose_cost(c,angle),c.a,c.b,backend;eta=.002,tolerance=1e-4,accelerate=true)
            end
            trial=copy(seed);trial[k]=result.plan
            value=score(trial)
            if value<best && within(CE.metrics(countries,trial,edges))
                seed=trial;best=value;chosen=angle
            end
            GC.gc()
        end
        angles[c.code]=chosen
        CE.checkpoint(path,(;plan=seed[k],angle=chosen,objective=best))
        push!(rows,(;code=c.code,angle=chosen,objective=best))
        CSV.write(joinpath(out,"poses.csv"),DataFrame(rows))
    end
    CSV.write(joinpath(out,"poses.csv"),DataFrame(rows))
    return (;seed,angles,factors,strength,fold_strength)
end

function coarse_countries(countries,out,resolution)
    mkpath(joinpath(out,"sources"))
    result=NamedTuple[]
    for c in countries
        all(id->H3.API.getResolution(id)>=resolution,c.source.id) || error("cannot refine source data during pose selection")
        mass=Dict{UInt64,Float64}()
        for r in eachrow(c.source)
            id=H3.API.cellToParent(r.id,resolution)
            mass[id]=get(mass,id,0.)+r.value
        end
        ids=sort!(collect(keys(mass)))
        path=joinpath(out,"sources","$(c.code).arrow")
        if !isfile(path)
            Arrow.write(path,(;id=ids,population=[mass[id] for id in ids],country_code=fill(c.code,length(ids))))
        end
        coarse=CE.country(path,c.code;target=c.target,dense=false)
        hasproperty(c,:cut_targets) && (coarse=merge(coarse,(;cut_targets=c.cut_targets)))
        isapprox(sum(coarse.source.value),sum(c.source.value);rtol=1e-12) || error("coarse population differs")
        push!(result,coarse)
    end
    return result
end

function fit(out;compact=false,pose_resolution=compact ? 4 : 5)
    oneAPI.functional() || error("oneAPI is not functional; no CPU fallback")
    0<=pose_resolution<=5 || error("invalid coarse pose resolution")
    compact || pose_resolution==5 || error("coarse pose selection requires compact mode")
    ispath(joinpath(out,"fit")) && error("fit already exists; use continue_fit.jl to resume a checkpoint")
    cache_bytes=parse(Int,get(ENV,"CONTINUITY_COMPACT_CACHE_BYTES",string(512*1024^2)))
    cache_bytes>=0 || error("invalid device cost cache budget")
    config=DataFrame(compact=[compact],pose_resolution=[pose_resolution],cache_bytes=[cache_bytes])
    configpath=joinpath(out,"fit-config.csv")
    isfile(configpath) && CSV.read(configpath,DataFrame)!=config && error("cached fit configuration differs")
    CSV.write(configpath,config)
    backend=oneAPI.oneAPIBackend()
    open(joinpath(out,"provenance.txt"),"a") do io
        println(io,"Fit started: $(now(UTC)) UTC\nFit commit: ",strip(read(`git rev-parse HEAD`,String)))
    end
    oneAPI.versioninfo();flush(stdout)
    metadata=CSV.read(joinpath(out,"countries.csv"),DataFrame)
    active=Set(metadata.code[metadata.fitted])
    targets=deserialize(joinpath(out,"targets.jls"))
    countries_path=joinpath(out,"countries.jls")
    countries=if isfile(countries_path)
        deserialize(countries_path)
    else
        owners=Dict{Tuple{Int,Int},Int}()
        for c in targets,r in eachrow(c.target)
            pos=(Int(r.x),Int(r.y));owners[pos]=get(owners,pos,0)+1
        end
        cuts=Set(pos for (pos,n) in owners if n>1)
        cs=[merge(CE.country(joinpath(out,"sources","$(c.code).arrow"),c.code;target=c.target,dense=!compact),
                  (;cut_targets=cuts)) for c in targets if c.code in active]
        CE.checkpoint(countries_path,cs)
        cs
    end
    all(c->(c.cost isa CE.GeometryCost)==compact,countries) || error("cached country representation differs")
    br=CSV.read(joinpath(out,"borders.csv"),DataFrame)
    borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(br) if r.country_a in active && r.country_b in active)
    edges=CE.graph(countries;borders)
    contacts=CSV.read(joinpath(out,"contacts.csv"),DataFrame)
    count(e->e[1]!=e[3],edges)==sum(contacts.edges[contacts.fitted]) || error("fitted contact mask changed")
    proposals=nothing
    if pose_resolution<5
        coarseout=joinpath(out,"coarse-poses")
        coarse=coarse_countries(countries,coarseout,pose_resolution)
        coarsebaseline=planet_baseline(coarse,backend,coarseout;compact=true,cache_bytes)
        proposals=planet_poses(coarse,coarsebaseline,borders,backend,coarseout;compact=true,cache_bytes).angles
        GC.gc()
    end
    baseline=planet_baseline(countries,backend,out;compact,cache_bytes)
    chosen=planet_poses(countries,baseline,borders,backend,out;compact,proposals,cache_bytes)
    CE.run_case(countries,backend,joinpath(out,"fit");initial_plans=baseline,starting_plans=chosen.seed,
        compact,borders,border_factors=chosen.factors,strength=chosen.strength,eta=.002,border_share=.25,scale_km=900.,
        form=:distribution,saturating=false,fold_strength=chosen.fold_strength,proximal=.1,coordinate=true,
        outer_steps=parse(Int,get(ENV,"CONTINUITY_OUTER_STEPS","10")),
        interior_limit=4.,spread_limit=1.25,inner_tolerance=1e-4,accelerate=true,export_arrow=false,
        checkpoint_interval=compact ? 1 : length(countries),compact_cache_bytes=cache_bytes)
    write(joinpath(out,"fit-complete.txt"),"Completed: $(now(UTC)) UTC\n")
end
