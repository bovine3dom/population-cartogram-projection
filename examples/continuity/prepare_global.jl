using Arrow, DataFrames, SHA
include(joinpath(@__DIR__,"..","..","scripts","extract_kontur_country.jl"))

length(ARGS)>=4 || error("usage: prepare_global.jl GLOBAL_HILO.arrow OUTPUT_DIRECTORY RESOLUTION COUNTRY_CODES...")
input,outdir=abspath.(ARGS[1:2])
resolution=parse(Int,ARGS[3])
codes=parse.(Int,ARGS[4:end])
ispath(outdir) && error("refusing to overwrite $outdir")
mkpath(outdir)
raw=DataFrame(Arrow.Table(input))
raw=filter(r -> r.code in codes,raw)
raw.id=(UInt64.(raw.index_upper) .<< 32) .| UInt64.(raw.index_lower)
for code in codes
    source=unique(select(filter(r -> r.code==code,raw),:id,:population))
    isempty(source) && error("no source population for $code")
    allunique(source.id) || error("conflicting source populations")
    all(p -> isfinite(p) && p>0,source.population) || error("invalid source population")
    all(id -> KonturCountryExtract.H3.API.isValidCell(id) &&
              KonturCountryExtract.H3.API.getResolution(id)>=resolution,source.id) ||
        error("invalid H3 source resolution")
    result=KonturCountryExtract.aggregate_sources(source.id,source.population,code,resolution)
    Arrow.write(joinpath(outdir,"country-$code-res$resolution.arrow"),result)
    println("country=$code sources=$(nrow(result)) population=$(sum(result.population))")
end
open(joinpath(outdir,"input.sha256"),"w") do io
    println(io,bytes2hex(open(sha256,input)),"  ",input)
end
