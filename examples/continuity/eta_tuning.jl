# Included inside ContinuityExperiment. Tune the unforced baseline only.
include("sharpness.jl")

function compact_tune(c,backend;etas=PCP.ETA_CANDIDATES,
                      target_rows=2(length(c.a)+length(c.b)),retained=.995,
                      stage_callback=(record,result)->nothing,kwargs...)
    schedule=sort!(unique(Float64.(etas));rev=true)
    !isempty(schedule) && all(e->isfinite(e)&&e>0,schedule) || error("invalid eta schedule")
    isfinite(target_rows) && target_rows>=max(length(c.a),length(c.b)) || error("invalid support target")
    0<retained<=1 || error("invalid retained fraction")
    allunique(zip(c.target.x,c.target.y)) || error("duplicate target coordinates")
    best=nothing;best_error=Inf;beta=nothing;stages=NamedTuple[]
    for eta in schedule
        started=time()
        result=try
            compact_solve(c,zeros(3,length(c.b)),nothing,backend;eta,initial_beta=beta,kwargs...)
        catch err
            err isa CompactConvergenceError || rethrow()
            record=(;eta,converged=false,rows=missing,iterations=missing,
                marginal_error=missing,target_relative=missing,seconds=time()-started)
            push!(stages,record);stage_callback(record,nothing)
            nothing
        end
        isnothing(result) && break
        beta=result.beta
        support=ContinuitySharpness.retained_support(result.plan,(p,r)->exp.(logblock(p,r));retained)
        record=(;eta,converged=true,rows=support.rows,iterations=result.iterations,
            marginal_error=result.marginal_error,
            target_relative=maximum(abs.(result.plan.stats.target./c.b.-1)),seconds=time()-started)
        push!(stages,record);stage_callback(record,result)
        row_error=abs(support.rows-target_rows)
        if row_error<best_error
            best=(;eta,result,support);best_error=row_error
        end
        support.rows<=target_rows && break
        GC.gc()
    end
    isnothing(best) && error("no eta candidate passed the mass checks")
    return (;best...,stages,target_rows,retained,target_met=best.support.rows<=target_rows)
end
