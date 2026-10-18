using DataFrames
import KernelAbstractions as KA
import PopulationCartogramProjection

# Equal Earth (EPSG method 1078), north-positive coordinates.
function equal_earth(longitude, latitude)
    theta=asin(sqrt(3)/2*sin(latitude))
    a,b,c,d=1.340264,-0.081106,0.000893,0.003796
    (2sqrt(3)*longitude*cos(theta)/(3*(a+3b*theta^2+theta^6*(7c+9d*theta^2))),
     theta*(a+b*theta^2+theta^6*(c+d*theta^2)))
end

function unique_lookup(rows, key, value)
    result=Dict(key(r)=>value(r) for r in rows)
    length(result)==length(rows) || error("Duplicate lookup keys")
    result
end

"""Keep native component membership when H3 cells are aggregated.

Targets use the declared population pool, which can contain several artwork
pieces. Never infer a component from the centre of a coarse H3 cell.
"""
function mapping_inputs(build; resolution=5)
    resolution isa Integer && 0<=resolution<=8 || error("Resolution must be in 0:8")
    JSON.parsefile(joinpath(build,"build.json"))["complete"] || error("Incomplete layout build")
    source=joinpath(build,"sources");layout=joinpath(build,"layout")
    budgets=collect(CSV.File(joinpath(layout,"budgets.csv")))
    groups=unique_lookup(budgets,r->String(r.group_id),r->(pool=String(r.population_group),country=String(r.country),tiles=Int(r.tiles)))
    assignments=collect(CSV.File(joinpath(layout,"source-assignments.csv")))
    owners=unique_lookup(assignments,r->String(r.component_id),r->String(r.group_id))
    expected=Dict(String(r.component_id)=>Float64(r.population) for r in assignments)
    pool_country=Dict{String,String}()
    for g in values(groups)
        get!(pool_country,g.pool,g.country)==g.country || error("Population pool crosses countries")
        haskey(groups,g.pool) && groups[g.pool].pool==g.pool || error("Invalid population pool root")
    end
    for r in assignments
        get(pool_country,String(r.group_id),nothing)==r.country || error("Source assignment crosses countries")
    end
    originals=collect(CSV.File(joinpath(source,"original-components.csv")))
    dissolved=unique_lookup(collect(CSV.File(joinpath(source,"original-to-dissolved.csv"))),r->String(r.original_component_id),r->String(r.component_id))
    components=unique_lookup(originals,r->Int(r.component_index),r->dissolved[String(r.component_id)])
    native=Arrow.Table(joinpath(source,"source-membership.arrow"))
    length(native.id)==length(native.population)==length(native.original_component_index) || error("Invalid membership columns")
    sorted_ids=sort!(UInt64.(native.id))
    all(i->sorted_ids[i]!=sorted_ids[i-1],2:length(sorted_ids)) || error("Duplicate native H3 IDs")
    sorted_ids=nothing
    totals=Dict{Tuple{String,UInt64},Vector{Float64}}()
    component_mass=Dict(c=>0.0 for c in keys(owners))
    excluded=Dict("unmatched"=>0.0,"ambiguous"=>0.0,"unrepresented"=>0.0)
    input_mass=0.0
    for (id,mass,index) in zip(native.id,native.population,native.original_component_index)
        H3.API.isValidCell(id) && H3.API.getResolution(id)==8 || error("Expected native H3-8 membership")
        isfinite(mass) && mass>0 || error("Invalid native population")
        input_mass+=mass
        if index<=0
            index in (0,-1) || error("Invalid membership index")
            excluded[index==0 ? "unmatched" : "ambiguous"]+=mass
            continue
        end
        component=components[index]
        if !haskey(owners,component)
            excluded["unrepresented"]+=mass
            continue
        end
        parent=UInt64(H3.API.cellToParent(id,resolution))
        point=H3.API.cellToLatLng(id);x,y=equal_earth(point.lng,point.lat)
        v=get!(() -> zeros(3),totals,(component,parent))
        v[1]+=mass;v[2]+=mass*x;v[3]+=mass*y
        component_mass[component]+=mass
    end
    all(isapprox(component_mass[c],m;rtol=1e-10) for (c,m) in expected) || error("Component populations changed")
    sources=DataFrame([(id=i,component_id=c,group_id=owners[c],h3=h,value=v[1],x=v[2]/v[1],y=v[3]/v[1])
        for (i,((c,h),v)) in enumerate(sort!(collect(totals);by=first))])
    targets=DataFrame([(x=Int(r.x),y=Int(r.y),artwork_group=String(r.component_id),
        group_id=groups[String(r.component_id)].pool,country=groups[String(r.component_id)].country)
        for r in CSV.File(joinpath(layout,"cells.csv"))])
    for (g,info) in groups
        count(==(g),targets.artwork_group)==info.tiles || error("Tile budget mismatch for $g")
    end
    PopulationCartogramProjection._validate_inputs(targets,sources)
    Set(sources.group_id)==Set(targets.group_id) || error("Source and target pools differ")
    for r in budgets
        mass=sum(sources.value[sources.group_id.==r.population_group])
        isapprox(mass,r.pool_population;rtol=1e-10) || error("Pool population mismatch")
    end
    isapprox(sum(sources.value)+sum(values(excluded)),input_mass;rtol=1e-10) || error("Population accounting failed")
    unrepresented=collect(CSV.File(joinpath(layout,"source-scopes-without-tiles.csv")))
    isapprox(excluded["unrepresented"],sum((r.population for r in unrepresented);init=0.0);rtol=1e-10) || error("Unrepresented population changed")
    audit=Dict("resolution"=>resolution,"native_cells"=>length(native.id),"input_population"=>input_mass,
        "represented_population"=>sum(sources.value),"excluded_population"=>excluded,
        "component_h3_fragments"=>nrow(sources),"artwork_groups"=>length(groups),
        "population_pools"=>length(pool_country),"tiles"=>nrow(targets))
    (;sources,targets,audit)
end
