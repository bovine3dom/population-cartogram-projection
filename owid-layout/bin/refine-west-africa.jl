using OWIDLayout, CSV, JSON
const O=OWIDLayout
length(ARGS)==3 || error("Usage: refine-west-africa.jl CLEAN_BUILD OUTPUT_DIR MODE")
root,output,mode=ARGS
mode in ("conservative","geographic","conservative-soft","geographic-soft","conservative-local","geographic-local","geographic-seed","geographic-reseed","geographic-centres","geographic-centres-refined","geographic-centres-diagnostic") || error("Unknown mode")
local_search=endswith(mode,"-local")
centre_cost=startswith(mode,"geographic-centres")
reseed=endswith(mode,"-seed") || endswith(mode,"-reseed") || centre_cost
soft=endswith(mode,"-soft") || local_search || reseed
ispath(output) && error("Use a new output directory")
mkpath(output)
cp(@__FILE__,joinpath(output,"driver.jl"))
region=sort!(String.(split("MRT MLI NER NGA SEN GMB GNB GIN SLE LBR CIV BFA GHA TGO BEN")))
paths=[joinpath(root,"layout/cells.csv"),joinpath(root,"layout/components.csv"),joinpath(root,"sources/polygons.geojson")]
original=Dict((r.x,r.y)=>String(r.component_id) for r in CSV.File(paths[1]))
owner=Dict(p=>O.group_scope(g) for (p,g) in original)
reference=Dict(s=>Set(p for (p,c) in owner if c==s) for s in region)
budgets=Dict(s=>length(ps) for (s,ps) in reference)
footprint=Set(p for ps in values(reference) for p in ps)
outside=Dict(p=>s for (p,s) in owner if p ∉ footprint)
codes=O.code_table(joinpath(@__DIR__,"../config/country-codes.csv"))
sources=O.read_sources(paths[2],paths[3],codes)
scopes=Dict(p.id=>s for (s,ps) in sources for p in ps)
features=JSON.parsefile(paths[3])["features"]
neighbours=O.source_neighbours(features,scopes)
contacts=Set(minmax(scopes[id],s) for (id,ss) in neighbours for s in ss)
required=Set(pair for pair in contacts if all(s in region for s in pair))
# This pilot constrains internal neighbours to Natural Earth, not OWID.
# Outside countries remain fixed; their contacts are audited, not declared valid.
function audit(cells)
    actual=O.edge_contacts(cells)
    relevant=pair->any(s in region for s in pair)
    internal=pair->all(s in region for s in pair)
    false_contacts=sort!(collect(filter(relevant,setdiff(actual,contacts))))
    missing=sort!(collect(filter(relevant,setdiff(contacts,actual))))
    edges=Dict(s=>0 for s in region)
    for (p,s) in cells
        s in region || continue
        edges[s]+=count(get(cells,(p[1]+dx,p[2]+dy),"")!=s for (dx,dy) in O.EDGE_OFFSETS)
    end
    Dict("false_contacts"=>false_contacts,"missing_contacts"=>missing,
         "false_internal_contacts"=>filter(internal,false_contacts),"missing_internal_contacts"=>filter(internal,missing),
         "perimeters"=>edges,"total_perimeter"=>sum(values(edges)),
         "counts_exact"=>all(count(==(s),values(cells))==budgets[s] for s in region),
         "connected"=>all(length(O.connected_parts([p for (p,c) in cells if c==s];diagonals=true))==1 for s in region))
end
geometry=Dict(String(f["properties"]["component_id"])=>f["geometry"] for f in features)
main=Dict(s=>geometry[first(sort(sources[s];by=p->(-p.mass,p.id))).id] for s in region)
centres=Dict(s=>first(O.geometry_descriptor(main[s],0.,0.)) for s in region)
target=Dict(s=>O.cell_centre(reference[s]) for s in region)
# Fit positive, axis-aligned scales to the existing regional placement. Each
# country has equal weight; Nigeria must not determine every guide position.
function axis_fit(axis)
    x=[centres[s][axis] for s in region];y=[target[s][axis] for s in region]
    mx=sum(x)/length(x);my=sum(y)/length(y)
    scale=sum((x.-mx).*(y.-my))/sum((x.-mx).^2)
    scale>0 || error("Geographic axis is reversed")
    (my-scale*mx,scale)
end
axes=axis_fit.(1:2)
geo_guides=Dict{String,Set{Tuple{Int,Int}}}()
for s in region
    rings=main[s]["coordinates"]
    area=sum((j==1 ? 1 : -1)*abs(sum(r[i][1]*r[i+1][2]-r[i+1][1]*r[i][2] for i in 1:length(r)-1))/2 for (j,r) in enumerate(rings))
    factor=cosd(12.);scale=sqrt(budgets[s]/(area*factor))
    centre=ntuple(k->axes[k][1]+axes[k][2]*centres[s][k],2)
    guide=[[(centre[1]+scale*factor*(p[1]-centres[s][1]),centre[2]+scale*(p[2]-centres[s][2])) for p in r] for r in rings]
    outer=first(guide)
    mask=Set((x,y) for x in floor(Int,minimum(first,outer)):ceil(Int,maximum(first,outer)),
         y in floor(Int,minimum(last,outer)):ceil(Int,maximum(last,outer))
         if O.point_in_ring((x,y),outer) && !any(O.point_in_ring((x,y),r) for r in guide[2:end]))
    isempty(mask) && push!(mask,round.(Int,centre))
    geo_guides[s]=mask
end
points=sort!(collect(footprint))
distances(guides)=[minimum(sum((p[k]-q[k])^2 for k in 1:2) for q in guides[s]) for p in points,s in region]
oldcost=distances(reference);geocost=distances(geo_guides)
blend=startswith(mode,"conservative") ? .25 : .85
costs=(1-blend).*oldcost.+blend.*geocost
if centre_cost
    costs=[sum((p[k]-(axes[k][1]+axes[k][2]*centres[s][k]))^2 for k in 1:2) for p in points,s in region]
end
costs.-=minimum(costs;dims=2)
# A mainland outer edge not shared with another source scope is coastline.
# Interior rings are not coastline: this must not turn lakes into sea access.
segment(a,b)=minmax(Tuple(round.(Float64.(a);digits=7)),Tuple(round.(Float64.(b);digits=7)))
edge_scopes=Dict{Tuple{NTuple{2,Float64},NTuple{2,Float64}},Set{String}}()
for f in features
    id=String(f["properties"]["component_id"]);haskey(scopes,id) || continue
    for ring in f["geometry"]["coordinates"],i in 1:length(ring)-1
        ring[i]==ring[i+1] && continue
        push!(get!(edge_scopes,segment(ring[i],ring[i+1]),Set{String}()),scopes[id])
    end
end
inland=Set(s for s in region if all(any(t!=s for t in edge_scopes[segment(r[i],r[i+1])])
    for r in [first(main[s]["coordinates"])] for i in 1:length(r)-1 if r[i]!=r[i+1]))
report=Dict{String,Any}("complete"=>false,"approved"=>false,"mode"=>mode,"region"=>region,"tiles"=>length(footprint),
    "before"=>audit(owner),"geographic_weight"=>blend,"guide_axes"=>axes,"inland"=>sort!(collect(inland)),
    "topology_mode"=>soft ? "audit or penalty; errors are not approved" : "exact internal graph",
    "cell_cost"=>centre_cost ? "squared distance to geographic guide centres" : "blended distance to original and geographic shape guides",
    "inputs"=>Dict(p=>O.file_digest(p) for p in [paths;@__FILE__;joinpath(@__DIR__,"../src/partition.jl");joinpath(@__DIR__,"../src/region_exchange.jl");joinpath(@__DIR__,"../src/region_seed.jl")]),
    "limits"=>["The regional footprint and all outside countries stay fixed.","Natural Earth defines desired contacts. Penalized trials can retain errors; outside contacts are audited only.","This experiment does not add missing lakes."])
save()=open(io->JSON.print(io,report),joinpath(output,"report.json"),"w")
save()
CSV.write(joinpath(output,"before.csv"),[(component_id=g,x=p[1],y=p[2]) for (p,g) in sort!(collect(original);by=first)])
attempts=Any[]
for radius in (reseed || local_search ? (8.,) : (8.,16.))
    println("Starting $mode: $(length(points)) tiles, radius=$radius");flush(stdout)
    if reseed
        function checkpoint(candidate,iteration)
            candidate_owner=merge(copy(outside),O.group_owners(candidate))
            progress=Dict("complete"=>false,"iteration"=>iteration,"audit"=>audit(candidate_owner),
                "disconnected"=>Dict(g=>length.(O.connected_parts(ps;diagonals=true)) for (g,ps) in candidate if length(O.connected_parts(ps;diagonals=true))>1))
            CSV.write(joinpath(output,"candidate.csv"),[(component_id=g,x=p[1],y=p[2]) for (p,g) in sort!(collect(candidate_owner);by=first)])
            open(io->JSON.print(io,progress),joinpath(output,"candidate-report.json"),"w")
            println("Disconnected countries: ",JSON.json(progress["disconnected"]));flush(stdout)
        end
        result,check=O.seed_region(reference,outside,costs;inland,rounds=endswith(mode,"-diagnostic") ? 1 : 100,checkpoint,monotone=centre_cost)
        if result!==nothing && (endswith(mode,"-reseed") || endswith(mode,"-refined"))
            report["seed_audit"]=audit(merge(copy(outside),O.group_owners(result)))
            result,check=O.exchange_region(result,outside,required,costs;inland)
        end
    elseif local_search
        result,check=O.exchange_region(reference,outside,required,costs;inland)
    else
        result,check=O.partition_groups(reference,footprint,budgets;required,outside,inland,cell_costs=costs,
            perimeter_weight=2.,free_outside_contacts=true,radius,node_limit=soft ? 30 : 250,rounds=20,
            contact_penalty=soft ? 200. : nothing,start_reference=soft)
    end
    push!(attempts,check);report["attempts"]=attempts;save()
    isnothing(result) && continue
    fitted=merge(copy(outside),O.group_owners(result))
    report["after"]=audit(fitted)
    report["complete"]=true
    report["changed_cells"]=count(fitted[p]!=owner[p] for p in footprint)
    # All pilot countries have one group. Retain original IDs outside the pilot.
    all(length(unique(original[p] for p in reference[s]))==1 for s in region) || error("Pilot scope has multiple groups")
    ids=Dict(s=>original[first(reference[s])] for s in region)
    final=merge(copy(original),Dict(p=>ids[s] for (p,s) in fitted if p in footprint))
    CSV.write(joinpath(output,"cells.csv"),[(component_id=g,x=p[1],y=p[2]) for (p,g) in sort!(collect(final);by=first)])
    save();println("Finished $mode: ",JSON.json(report["after"]));break
end
report["complete"] || error("No validated regional fit; see report.json")
