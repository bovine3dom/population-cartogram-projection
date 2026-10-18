using OWIDLayout, CSV, JSON, SHA

length(ARGS)==6 || error("Usage: resize-corner-groups.jl OWID.csv SAVED_DIR COMPONENTS.csv POLYGONS.geojson OUTPUT_DIR MODE")
owid,parent,components,polygons,output,mode=ARGS
mode in ("audit","fit") || error("MODE must be audit or fit")
ispath(output) && error("Use a new output directory")
codes=OWIDLayout.code_table(joinpath(@__DIR__,"..","config","country-codes.csv"))
inventory=read_target_groups(owid,codes)
member=Dict(r.target_id=>r.group_id for r in inventory.membership)
rawparent=collect(CSV.File(joinpath(parent,"cells.csv")))
for r in rawparent
    id=String(r.component_id)
    haskey(member,id) || (member[id]=first(split(id,':'))*":G1")
end
current=Dict{String,Set{Tuple{Int,Int}}}()
for r in rawparent; push!(get!(current,member[r.component_id],Set{Tuple{Int,Int}}()),(r.x,r.y)); end
scopes=sort!(unique(r.scope for r in inventory.membership if count(q->q.group_id==r.group_id,inventory.membership)>1))
sources=read_sources(components,polygons,codes)
source_rows=Dict(String(r.component_id)=>r for r in CSV.File(components;types=String))
features=JSON.parsefile(polygons)["features"]
geometry=Dict(String(f["properties"]["component_id"])=>f["geometry"] for f in features)
source_scopes=Dict(p.id=>scope for (scope,ps) in sources for p in ps)
neighbours=OWIDLayout.source_neighbours(features,source_scopes)
target_neighbours=Dict{String,Set{String}}()
for reference in (inventory.groups,inventory.pieces)
    reference_owner=Dict(p=>g for (g,ps) in reference for p in ps)
    for g in keys(reference); target_neighbours[g]=Set{String}(); end
    for (p,g) in reference_owner,(dx,dy) in OWIDLayout.EDGE_OFFSETS
        q=(p[1]+dx,p[2]+dy); other=get(reference_owner,q,g)
        first(split(other,':'))==first(split(g,':')) || push!(target_neighbours[g],first(split(other,':')))
    end
end
budgets=Dict(g=>length(ps) for (g,ps) in current)
assignments=NamedTuple[]; reports=NamedTuple[]
for scope in scopes
    groups=sort!([g for g in keys(inventory.groups) if startswith(g,"$scope:")])
    targets=[OWIDLayout.describe_cells(g,inventory.groups[g]) for g in groups]
    children=[OWIDLayout.describe_cells(id,ps) for (id,ps) in inventory.pieces if startswith(id,"$scope:")]
    result=OWIDLayout.match_group_population(sources[scope],targets,geometry,source_rows,sum(budgets[g] for g in groups);
        target_neighbours,source_neighbours=Dict(p.id=>neighbours[p.id] for p in sources[scope]),
        children,membership=member,target_cells=inventory.groups)
    merge!(budgets,result.budgets)
    append!(assignments,[(;country=scope,r...) for r in result.assignments])
    append!(reports,[(;country=scope,before=length(current[r.group_id]),r...) for r in result.groups])
    println(scope," ",[(r.group_id,length(current[r.group_id]),r.tiles) for r in result.groups])
end
# Keep all other source assignments, but map their T IDs to the new G IDs.
for r in CSV.File(joinpath(parent,"source-assignments.csv");types=String)
    r.country in scopes && continue
    push!(assignments,(country=String(r.country),component_id=String(r.component_id),group_id=member["$(r.country):$(r.target_part)"],
          population=parse(Float64,r.population),assignment="retained_parent_assignment",source_distance=ismissing(r.source_distance) ? NaN : parse(Float64,r.source_distance)))
end
sort!(assignments;by=r->(r.country,r.component_id))
length(unique(r.component_id for r in assignments))==length(assignments) || error("Duplicate population assignment")
oldmass=sum(parse(Float64,r.population) for r in CSV.File(joinpath(parent,"source-assignments.csv");types=String))
newmass=sum(r.population for r in assignments)
oldmass==newmass || error("Population changed: $oldmass -> $newmass")
mkdir(output)
CSV.write(joinpath(output,"budgets.csv"),reports)
CSV.write(joinpath(output,"source-assignments.csv"),assignments)
CSV.write(joinpath(output,"membership.csv"),[(target_id=id,group_id=g) for (id,g) in sort!(collect(member);by=first)])
CSV.write(joinpath(output,"before.csv"),[(component_id=g,x=p[1],y=p[2]) for g in sort!(collect(keys(current))) for p in sort!(collect(current[g]))])
inputs=[owid,components,polygons,joinpath(parent,"cells.csv"),joinpath(parent,"source-assignments.csv"),@__FILE__]
append!(inputs,[joinpath(@__DIR__,"..","src",f) for f in readdir(joinpath(@__DIR__,"..","src")) if endswith(f,".jl")])
record=Dict{String,Any}("complete"=>false,"approved"=>false,"mode"=>mode,"changed_scopes"=>scopes,
    "population"=>newmass,"land_tiles"=>sum(values(budgets)),"groups"=>length(current),
    "policy"=>Dict("minimum_tiles_per_group"=>1,"anchor_minimum_quota"=>0.5,"anchor_unary_cost_limit"=>0.12,
        "free_group_translation_radius"=>24,"land_connectivity"=>8,"water_connectivity"=>4),
    "limits"=>["Only corner-affected scopes are rematched; other assignments are retained.",
        "Fallback source distances use centroid-to-polygon distance in a local plane.",
        "Source preparation still uses existing Natural Earth/Kontur intermediates.",
        "Shared-border cells stay fixed; no new shared-island border fit is performed."],
    "inputs"=>Dict(p=>open(io->bytes2hex(sha256(io)),p) for p in inputs))
if mode=="fit"
    fitted,details=OWIDLayout.resize_groups(current,inventory.groups,budgets)
    record["fit"]=details
    if fitted!==nothing
        CSV.write(joinpath(output,"cells.csv"),[(component_id=g,x=p[1],y=p[2]) for g in sort!(collect(keys(fitted))) for p in sort!(collect(fitted[g]))])
        record["complete"]=true
    end
end
open(io->JSON.print(io,record),joinpath(output,"report.json"),"w")
mode=="fit" && !record["complete"] && exit(2)
