# Native population extraction for the H3-6 refinement study.
using Arrow,CSV,DataFrames,H3,JSON,Dates
include("../../scripts/extract_kontur_country.jl")
include("native_membership.jl")

function prepare_native6(raw_path,coarse_path,out;codes=nothing)
    ispath(out) && error("refusing to overwrite $out")
    coarse=DataFrame(Arrow.Table(coarse_path))
    allowed=isnothing(codes) ? sort!(unique(Int.(coarse.code))) : sort!(unique(codes))
    !isempty(allowed) && all(code->0<code<=typemax(Int32),allowed) || error("invalid country codes")
    all(in(Set(Int.(coarse.code))),allowed) || error("country has no coarse artwork")
    table=Arrow.Table(raw_path)
    ids=UInt64.(collect(table.h3))
    all(id->H3.API.isValidCell(id)&&H3.API.getResolution(id)==8,ids) || error("expected valid H3-8")
    sorted=issorted(ids) ? ids : sort(ids)
    any(i->sorted[i]==sorted[i-1],2:length(sorted)) && error("duplicate input")
    population=Float64.(collect(table.population))
    all(p->isfinite(p)&&p>0,population) || error("invalid population")
    boundaries=JSON.parsefile(KonturCountryExtract.DEFAULT_BOUNDARY)
    owner,overlaps=NativeMembership.point_owners(ids,boundaries,allowed)
    # A browser source must have a single country owner. Keep all selected
    # population, but assign a shared H3-6 cell to its largest population share.
    masses=Dict{Tuple{UInt64,Int32},Float64}()
    for (i,id) in enumerate(table.h3)
        owner[i]==0 && continue
        key=(H3.API.cellToParent(id,6),owner[i])
        masses[key]=get(masses,key,0.)+population[i]
    end
    shares=sort!([(id=id,code=code,population=p) for ((id,code),p) in masses];by=x->(x.id,x.code))
    rows=NamedTuple[];shared=0;reassigned=0.;i=1
    while i<=length(shares)
        j=i
        while j<length(shares) && shares[j+1].id==shares[i].id;j+=1;end
        group=view(shares,i:j);winner=argmax(r->r.population,group)
        total=sum(r->r.population,group)
        push!(rows,(id=winner.id,country_code=Int(winner.code),population=total))
        shared+=(j>i);reassigned+=total-winner.population;i=j+1
    end
    result=DataFrame(rows)
    allunique(result.id) || error("duplicate output source")
    selected=sum(population[i] for i in eachindex(owner) if owner[i]!=0)
    isapprox(sum(result.population),selected;rtol=1e-12) || error("population changed")
    mkpath(out);Arrow.write(joinpath(out,"all-res6.arrow"),result)
    for group in groupby(result,:country_code)
        Arrow.write(joinpath(out,"country-$(first(group.country_code))-res6.arrow"),group)
    end
    summary=combine(groupby(result,:country_code),nrow=>:sources,:population=>sum=>:population)
    before=Dict(code=>0. for code in allowed)
    for ((_,code),p) in masses;before[code]+=p;end
    summary.before_owner_merge=[before[code] for code in summary.country_code]
    CSV.write(joinpath(out,"countries.csv"),summary)
    missing=setdiff(allowed,result.country_code)
    CSV.write(joinpath(out,"missing-countries.csv"),DataFrame(country_code=missing))
    report=(;sources=nrow(result),population=selected,excluded_population=sum(population)-selected,
        overlapping_memberships=overlaps,shared_h3_6_cells=shared,reassigned_population=reassigned,missing_countries=length(missing))
    CSV.write(joinpath(out,"audit.csv"),DataFrame([report]));println(report)
    write(joinpath(out,"complete.txt"),"$(now(UTC)) UTC\n")
    return result
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)>=3 || error("usage: prepare_native6.jl H3_8.arrow COARSE_INPUT.arrow OUTPUT [COUNTRY_CODES...]")
    prepare_native6(ARGS[1:3]...;codes=length(ARGS)>3 ? parse.(Int,ARGS[4:end]) : nothing)
end
