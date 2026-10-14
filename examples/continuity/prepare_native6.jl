# Native population extraction for the H3-6 refinement study.
using Arrow,CSV,DataFrames,H3,JSON,Dates
include("../../scripts/extract_kontur_country.jl")

function prepare_native6(raw_path,coarse_path,out;codes=nothing)
    ispath(out) && error("refusing to overwrite $out")
    coarse=DataFrame(Arrow.Table(coarse_path))
    allowed=isnothing(codes) ? sort!(unique(Int.(coarse.code))) : sort!(unique(codes))
    all(in(Set(Int.(coarse.code))),allowed) || error("country has no coarse artwork")
    table=Arrow.Table(raw_path)
    lookup=Dict{UInt64,Int32}()
    length(table.h3)<=typemax(Int32) || error("too many population rows")
    for (i,id) in enumerate(table.h3)
        H3.API.isValidCell(id) && H3.API.getResolution(id)==8 || error("expected H3-8 input")
        haskey(lookup,id) && error("duplicate population cell")
        lookup[id]=i
    end
    population=Float64.(collect(table.population))
    all(p->isfinite(p)&&p>0,population) || error("invalid population")
    # One owner per native cell. Resolve polygon overlap by numeric country code.
    owner=zeros(Int32,length(population));overlaps=0
    boundaries=JSON.parsefile(KonturCountryExtract.DEFAULT_BOUNDARY)
    for code in allowed
        found=false
        for feature in boundaries["features"]
            string(feature["properties"]["ISO_N3_EH"])==lpad(string(code),3,'0') || continue
            found=true;geometry=feature["geometry"]
            geometry["type"] in ("Polygon","MultiPolygon") || error("unsupported boundary")
            polygons=geometry["type"]=="Polygon" ? [geometry["coordinates"]] : geometry["coordinates"]
            for polygon in polygons
                cells=KonturCountryExtract.polygon_cells(polygon,8)
                for id in cells
                    row=get(lookup,id,Int32(0));row==0 && continue
                    if owner[row]!=0 && owner[row]!=code
                        overlaps+=1
                    else
                        owner[row]=code
                    end
                end
            end
        end
        println(now(UTC)," country=",code," boundary_found=",found);flush(stdout)
        GC.gc(false)
    end
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
    selected=sum(population[owner.!=0])
    isapprox(sum(result.population),selected;rtol=1e-12) || error("population changed")
    mkpath(out);Arrow.write(joinpath(out,"all-res6.arrow"),result)
    for group in groupby(result,:country_code)
        Arrow.write(joinpath(out,"country-$(first(group.country_code))-res6.arrow"),group)
    end
    CSV.write(joinpath(out,"countries.csv"),combine(groupby(result,:country_code),nrow=>:sources,:population=>sum=>:population))
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
