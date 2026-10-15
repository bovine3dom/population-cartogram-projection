using Serialization,Dates,CSV,SHA,TOML
include("mobile/soft_moments.jl")
const SM=SoftMomentPacking
function checkpoint(path,value)
    serialize(path*".tmp",value);mv(path*".tmp",path;force=true)
end
function main()
    length(ARGS)>=5||error("usage: pack_native.jl FIT FACTOR TARGET_RETAINED FORWARD_TOLERANCE NEW_OUTPUT [COUNTRIES...]")
    fit=ARGS[1];factor=parse(Int,ARGS[2]);retained,tolerance=parse.(Float64,ARGS[3:4]);out=ARGS[5]
    1<=factor<=5&&0<=retained<=1&&isfinite(tolerance)&&tolerance>=0||error("invalid packing limits")
    isfile(joinpath(fit,"fit-complete.txt"))||error("source fit is incomplete")
    manifest=TOML.parsefile(joinpath(fit,"input.toml"))
    codes=length(ARGS)>5 ? parse.(Int,ARGS[6:end]) : manifest["codes"]
    allunique(codes)&&issubset(Set(codes),Set(manifest["codes"]))||error("invalid countries")
    get(manifest,"factor",factor)==factor||error("factor differs from source fit")
    digest=bytes2hex(sha256(join([bytes2hex(open(sha256,joinpath(fit,"country-$code","part.jls"))) for code in sort(codes)],"")))
    commit=strip(read(`git rev-parse HEAD`,String));mkpath(out)
    input=(;fit=abspath(fit),fit_sha256=digest,codes=sort(codes),factor,target_retained=retained,forward_tolerance=tolerance)
    config=joinpath(out,"input.toml")
    if isfile(config)
        saved=TOML.parsefile(config)
        all(saved[string(k)]==v for (k,v) in pairs(input))||error("resume input differs")
    else
        open(io->TOML.print(io,Dict(string(k)=>v for (k,v) in pairs(merge(input,(;commit,started_utc=string(now(UTC)),
            model="Bounded moment packing after native KA/oneAPI fitting; not a new border pass"))))),config,"w")
    end
    deadline=datetime2unix(DateTime(get(ENV,"H3_PACK_DEADLINE","2026-10-15T04:10:00")))
    sizes=Dict(code=>length(deserialize(joinpath(fit,"country-$code","part.jls")).weights) for code in codes)
    sort!(codes;by=code->sizes[code],rev=true)
    for code in codes
        dir=joinpath(out,"country-$code");isfile(joinpath(dir,"part.jls"))&&continue
        time()<deadline||break
        mkpath(dir);println(now(UTC)," country=",code," factor=",factor);flush(stdout)
        try
            original=deserialize(joinpath(fit,"country-$code","part.jls"))
            seconds=@elapsed result=SM.pack_country(original;factor,target_retained=retained,tolerance,deadline)
            report=(;code,factor,commit,seconds,sources=length(original.meta.ids),targets=length(original.meta.targets),result.report...)
            CSV.write(joinpath(dir,"summary.csv"),[report]);CSV.write(joinpath(dir,"query-errors.csv"),result.queries)
            isempty(result.failures)||CSV.write(joinpath(dir,"block-failures.csv"),result.failures)
            checkpoint(joinpath(dir,"part.jls"),result.part);println(report);flush(stdout)
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
    length(finished)==length(codes)&&write(joinpath(out,"fit-complete.txt"),"Bounded moment packing of a checked native fit. No new border pass.\n")
    println("Completed countries: ",length(finished),"/",length(codes))
end
if abspath(PROGRAM_FILE)==@__FILE__
    main()
end
