using Serialization,Dates,CSV,SHA,TOML,Statistics
include("target_subdivision.jl")
const TS=TargetSubdivision
function checkpoint(path,value)
    serialize(path*".tmp",value);mv(path*".tmp",path;force=true)
end
function support_ratio(part)
    groups=[Float64[] for _ in part.meta.ids]
    for (i,w) in zip(part.source,part.weights);push!(groups[i],w);end
    sum(searchsortedfirst(cumsum(sort!(v;rev=true)),.995sum(v)) for v in groups)/length(groups)
end
function main()
    length(ARGS)>=3||error("usage: subdivide_native.jl COARSE_FIT FACTOR NEW_OUTPUT [COUNTRIES...]")
    coarse=ARGS[1];factor=parse(Int,ARGS[2]);out=ARGS[3]
    isfile(joinpath(coarse,"fit-complete.txt"))||error("coarse fit is incomplete")
    2<=factor<=5||error("factor must be 2 to 5")
    manifest=TOML.parsefile(joinpath(coarse,"input.toml"))
    codes=length(ARGS)>3 ? parse.(Int,ARGS[4:end]) : manifest["codes"]
    allunique(codes)&&issubset(Set(codes),Set(manifest["codes"]))||error("invalid country list")
    digest=bytes2hex(sha256(join([bytes2hex(open(sha256,joinpath(coarse,"country-$code","part.jls"))) for code in sort(codes)],"")))
    commit=strip(read(`git rev-parse HEAD`,String));mkpath(out)
    input=(;coarse=abspath(coarse),coarse_sha256=digest,codes=sort(codes),factor,density_moment=true)
    file=joinpath(out,"input.toml")
    if isfile(file)
        saved=TOML.parsefile(file)
        all(saved[string(k)]==v for (k,v) in pairs(input))||error("resume input differs")
    else
        open(io->TOML.print(io,Dict(string(k)=>v for (k,v) in pairs(merge(input,(;commit,started_utc=string(now(UTC)),model="CPU moment projection after KA/oneAPI native-source fitting"))))),file,"w")
    end
    deadline=datetime2unix(DateTime(get(ENV,"H3_SUBDIVISION_DEADLINE","2026-10-15T04:20:00")))
    sizes=Dict(code=>length(deserialize(joinpath(coarse,"country-$code","part.jls")).weights) for code in codes)
    sort!(codes;by=code->sizes[code],rev=true)
    for code in codes
        dir=joinpath(out,"country-$code");isfile(joinpath(dir,"part.jls"))&&continue
        time()<deadline||break
        mkpath(dir);println(now(UTC)," country=",code," factor=",factor);flush(stdout)
        try
            part=deserialize(joinpath(coarse,"country-$code","part.jls"))
            seconds=@elapsed result=TS.subdivide(part,factor;deadline,limit=factor==5 ? 120. : 30.)
            CSV.write(joinpath(dir,"cells.csv"),result.records)
            report=(;code,factor,commit,seconds,sources=length(part.meta.ids),targets=length(result.part.meta.targets),
                rows=length(result.part.weights),ratio995=support_ratio(result.part),
                amplitude_mean=mean(r.amplitude for r in result.records),amplitude_min=minimum(r.amplitude for r in result.records),
                uniform_fallbacks=count(r->!isempty(r.reason),result.records),source_error=result.source_error,target_error=result.target_error)
            CSV.write(joinpath(dir,"summary.csv"),[report]);checkpoint(joinpath(dir,"part.jls"),result.part)
            println(report);flush(stdout)
        catch err
            write(joinpath(dir,"error.log"),sprint(showerror,err,catch_backtrace()))
            println("FAILED country=",code," ",sprint(showerror,err));flush(stdout)
        end
        GC.gc(true)
    end
    finished=[code for code in codes if isfile(joinpath(out,"country-$code","part.jls"))]
    reports=[(; (name=>getproperty(row,name) for name in propertynames(row))...) for code in finished
        for row in CSV.File(joinpath(out,"country-$code","summary.csv"))]
    isempty(reports)||CSV.write(joinpath(out,"summary.csv"),reports)
    write(joinpath(out,"status.txt"),"$(length(finished))/$(length(codes)) countries complete at $(now(UTC)) UTC\n")
    length(finished)==length(codes)&&write(joinpath(out,"fit-complete.txt"),"Moment-constrained subdivision of the native-source fit. No new border pass.\n")
    println("Completed countries: ",length(finished),"/",length(codes))
end
if abspath(PROGRAM_FILE)==@__FILE__
    main()
end
