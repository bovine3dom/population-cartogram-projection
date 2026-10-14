using Serialization,Dates,oneAPI,CSV,DataFrames,SHA,TOML
include("experiment.jl")
include("sparse_refinement.jl")
include("mobile_export.jl")
include("native_hierarchy.jl")
include("local_balance.jl")
const NH=NativeHierarchy
function checkpoint(path,value)
    serialize(path*".tmp",value);mv(path*".tmp",path;force=true)
end
function main()
    length(ARGS)>=3 || error("usage: fit_native_sources.jl GUIDES NATIVE_SOURCE_DIR OUTPUT [COUNTRIES...]")
    guides,native,out=ARGS[1:3];mkpath(out)
    run_commit=strip(read(`git rev-parse HEAD`,String))
    deadline=datetime2unix(DateTime(get(ENV,"H3_NATIVE_DEADLINE","2026-10-15T04:25:00")))
    codes=length(ARGS)>3 ? parse.(Int,ARGS[4:end]) : deserialize(joinpath(guides,"codes.jls"))
    input_hash=bytes2hex(open(sha256,joinpath(native,"all-res6.arrow")))
    guide_hash=bytes2hex(sha256(join([bytes2hex(open(sha256,joinpath(guides,"country-$code.jls"))) for code in sort(codes)],"")))
    manifest=joinpath(out,"input.toml")
    if isfile(manifest)
        saved=TOML.parsefile(manifest)
        saved["native_sha256"]==input_hash && saved["guide_sha256"]==guide_hash && saved["codes"]==sort(codes) || error("resume input differs")
    else
        open(manifest,"w") do io
            TOML.print(io,Dict("native_sha256"=>input_hash,"guide_sha256"=>guide_hash,"native_directory"=>abspath(native),
                "guides"=>abspath(guides),"codes"=>sort(codes),"factor"=>1,"started_utc"=>string(now(UTC)),
                "commit"=>run_commit,"model"=>"native source refinement of the sharp H3-5 map"))
        end
    end
    sizes=Dict(code=>length(deserialize(joinpath(guides,"country-$code.jls")).meta.ids) for code in codes)
    sort!(codes;by=code->sizes[code],rev=true)
    backend=oneAPI.oneAPIBackend();failures=NamedTuple[]
    for code in codes
        dir=joinpath(out,"country-$code");isfile(joinpath(dir,"part.jls"))&&continue
        time()<deadline || break
        mkpath(dir);started=time();println(now(UTC)," Country ",code);flush(stdout)
        try
            guide=deserialize(joinpath(guides,"country-$code.jls"))
            state=NH.prepare(guide,joinpath(native,"country-$code-res6.arrow"))
            checkpoint(joinpath(dir,"state.jls"),state)
            projection=nothing
            if isfile(joinpath(dir,"projection.jls"))
                projection=deserialize(joinpath(dir,"projection.jls"))
            else
                projection=LocalBalance.balance(state)
                checkpoint(joinpath(dir,"projection.jls"),projection)
            end
            fit=nothing;status="optimized";reason=""
            try
                fit=NH.split_sources(state,projection,backend;deadline)
            catch err
                reason=sprint(showerror,err)
                (occursin("did not converge",reason)||occursin("deadline reached",reason))||rethrow()
                fit=NH.inherited(state,projection);status="inherited"
            end
            checkpoint(joinpath(dir,"fit.jls"),fit)
            packed=nothing
            for fraction in (.999,.9999,.99999,.999999,1.)
                try
                    packed=NH.pack_part(state,fit;fraction);break
                catch err
                    startswith(sprint(showerror,err),"packed country failed")||rethrow()
                    fraction==1. && rethrow()
                end
            end
            report=(;code,status,reason,commit=run_commit,seconds=time()-started,sources=length(state.d.a),targets=length(state.d.b),
                population=sum(state.d.source.value),rows=length(packed.part.weights),eta=fit.eta,
                ratio995=packed.ratio995,retained=packed.retained,max_centre_shift_km=packed.max_centre_shift_km,
                labels=length(packed.part.labels),label_fallbacks=packed.label_fallbacks,
                coarse_edges=length(projection.weights),components=projection.components,
                projection_method=projection.method,moved_mass=projection.moved_mass,packed.stats...)
            CSV.write(joinpath(dir,"summary.csv"),DataFrame([report]))
            checkpoint(joinpath(dir,"part.jls"),packed.part)
            println(report);flush(stdout)
        catch err
            message=sprint(showerror,err,catch_backtrace())
            write(joinpath(dir,"error.log"),message)
            push!(failures,(;code,error=sprint(showerror,err)))
            CSV.write(joinpath(out,"failures.csv"),DataFrame(failures))
            println("FAILED ",code,": ",sprint(showerror,err));flush(stdout)
        end
        GC.gc(true)
    end
    finished=[code for code in codes if isfile(joinpath(out,"country-$code","part.jls"))]
    if !isempty(finished)
        reports=vcat([CSV.read(joinpath(out,"country-$code","summary.csv"),DataFrame) for code in finished]...)
        CSV.write(joinpath(out,"summary.csv"),reports)
    end
    write(joinpath(out,"status.txt"),"$(length(finished))/$(length(codes)) countries complete at $(now(UTC)) UTC\n")
    length(finished)==length(codes) && write(joinpath(out,"fit-complete.txt"),"$(now(UTC)) UTC\nNative-source refinement; not a new border-optimization pass.\n")
    println("Completed countries: ",length(finished),"/",length(codes))
end
main()
