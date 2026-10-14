#!/usr/bin/env julia

module IslandTransport
using Arrow, CSV, DataFrames, H3, JSON
import KernelAbstractions as KA
include("prepare_layout.jl")
include(joinpath(@__DIR__, "..", "..", "src", "PopulationCartogramProjection.jl"))
const SCRIPT_HASH = LayoutInputs.Audit.file_hash(@__FILE__)

function coarse_sources(path, groups, resolution)
    0 <= resolution <= 8 || error("coarse resolution must be in 0:8")
    ids = Dict(last(split(r.component_id, ':')) => (String(r.component_id), String(r.group_id)) for r in eachrow(groups))
    length(ids) == nrow(groups) || error("duplicate source component hash")
    native = Arrow.Table(path)
    allunique(native.id) || error("duplicate source IDs")
    totals = Dict{Tuple{String,UInt64},Vector{Float64}}()
    anchors = Dict{String,String}()
    for (id,value,component) in zip(native.id,native.value,native.component_id)
        key = last(split(component, ':'))
        haskey(ids,key) || error("source component has no declared group")
        owner,group = ids[key]
        anchors[owner] = group
        isfinite(value) && value > 0 || error("invalid source population")
        H3.API.isValidCell(id) && H3.API.getResolution(id) == 8 || error("expected native H3-8 sources")
        parent = H3.API.cellToParent(id,resolution)
        centre = H3.API.cellToLatLng(id)
        x,y = LayoutInputs.project(rad2deg(centre.lng),rad2deg(centre.lat))
        total = get!(totals,(owner,parent),zeros(3))
        total .+= (value,value*x,value*y)
    end
    rows = [(;id="$component:$parent",component_id=component,group_id=anchors[component],
              value=v[1],x=v[2]/v[1],y=v[3]/v[1]) for ((component,parent),v) in sort!(collect(totals);by=first)]
    return DataFrame(rows)
end

function solve(targets, sources; pooled=false)
    PopulationCartogramProjection._validate_inputs(targets,sources)
    Set(targets.group_id) == Set(sources.group_id) || error("target and source groups differ")
    mappings = DataFrame[]
    for group in (pooled ? ["ALL"] : sort!(unique(sources.group_id)))
        s = pooled ? sources : filter(:group_id => ==(group),sources)
        t = pooled ? targets : filter(:group_id => ==(group),targets)
        println("Solving $group: $(nrow(s)) sources, $(nrow(t)) targets"); flush(stdout)
        if nrow(t) == 1 || nrow(s) == 1
            # The balanced solution is analytic in these degenerate cases.
            mapping = DataFrame([(;x=target.x,y=target.y,id=source.id,
                weight=1.0/nrow(t),weight_mean=source.value/sum(s.value))
                for source in eachrow(s) for target in eachrow(t)])
        else
            # The public solver expects screen coordinates (y increases down).
            # Mosaic exports use north-up coordinates. Convert only at the call.
            screen_targets = select(t,:x,:y)
            screen_targets.y = -screen_targets.y
            mapping = PopulationCartogramProjection.distribute(screen_targets,select(s,:x,:y,:value,:id);backend=KA.CPU())
            mapping.y = -mapping.y
        end
        push!(mappings,mapping)
    end
    result = vcat(mappings...)
    source_info = Dict(r.id => (r.group_id,r.value) for r in eachrow(sources))
    target_groups = Dict((r.x,r.y) => r.group_id for r in eachrow(targets))
    crossing = sum(r.weight*source_info[r.id][2] for r in eachrow(result)
        if source_info[r.id][1] != target_groups[(r.x,r.y)];init=0.0)
    retained = sum(r.weight*source_info[r.id][2] for r in eachrow(result))
    !pooled && crossing != 0 && error("cross-group transport escaped the wrapper")
    retained_weights = Dict(id=>0.0 for id in sources.id)
    for r in eachrow(result)
        retained_weights[r.id] += r.weight
    end
    return result, (;cross_group_population=crossing,retained_population=retained,
                    source_population=sum(sources.value),retained_share=retained/sum(sources.value),
                    minimum_source_retained_share=minimum(values(retained_weights)),
                    maximum_source_retained_share=maximum(values(retained_weights)))
end

function run(source_path, inputs, layout, output, resolution; pooled=false)
    ispath(output) && error("refusing to overwrite $output")
    isfile(joinpath(layout,"complete.txt")) || error("incomplete layout")
    groups = CSV.read(joinpath(inputs,"groups.csv"),DataFrame)
    any(ismissing, groups.group_id) && error("missing group")
    sources = coarse_sources(source_path,groups,resolution)
    targets = CSV.read(joinpath(layout,"cells.csv"),DataFrame)
    rename!(targets,:component_id=>:group_id)
    requested = Dict(String(r.component_id)=>Int(r.tiles) for r in eachrow(groups) if r.tiles > 0)
    actual = combine(groupby(targets,:group_id),nrow=>:tiles)
    Dict(String(r.group_id)=>r.tiles for r in eachrow(actual)) == requested || error("tile budgets do not match")
    for r in eachrow(groups)
        r.tiles > 0 || continue
        mass = sum(sources.value[sources.group_id .== r.component_id])
        isapprox(mass,r.group_population;rtol=1e-12) || error("group mass mismatch")
    end
    started = time()
    mapping, summary = solve(targets,sources;pooled)
    totals = Dict((r.x,r.y)=>0.0 for r in eachrow(targets))
    values = Dict(r.id=>r.value for r in eachrow(sources))
    for r in eachrow(mapping)
        totals[(r.x,r.y)] += values[r.id]*r.weight
    end
    expected = Dict(g=>sum(sources.value[sources.group_id .== g])/count(==(g),targets.group_id) for g in unique(targets.group_id))
    target_quality = DataFrame([(;x=r.x,y=r.y,group_id=r.group_id,population=totals[(r.x,r.y)],
        expected_population=pooled ? sum(sources.value)/nrow(targets) : expected[r.group_id]) for r in eachrow(targets)])
    target_quality.relative_error = target_quality.population ./ target_quality.expected_population .- 1
    metadata = Dict{String,Any}(string(k)=>v for (k,v) in pairs(summary))
    metadata["maximum_relative_target_error"] = maximum(abs,target_quality.relative_error)
    merge!(metadata,Dict("coarse_h3_resolution"=>resolution,"coarse_sources"=>nrow(sources),
        "targets"=>nrow(targets),"groups"=>length(unique(sources.group_id)),"pooled"=>pooled,
        "elapsed_seconds"=>time()-started,"backend"=>"CPU",
        "source_coordinates"=>"population-weighted Equal Earth centres; aggregate by input component and H3 parent",
        "target_coordinates"=>"north-up grid; y negated for the screen-coordinate solver, then restored in export",
        "script_sha256_at_load"=>SCRIPT_HASH,
        "limit"=>(resolution < 8 ? "Coarse transport experiment, not native H3-8 validation. " : "Native H3-8 centres. ") *
            "Grouped islands can exchange mass within their declared group. Each group has its own population per tile.",
        "inputs"=>[Dict("path"=>abspath(p),"sha256"=>LayoutInputs.Audit.file_hash(p)) for p in
            (source_path,joinpath(inputs,"groups.csv"),joinpath(layout,"cells.csv"))]))
    mkpath(dirname(abspath(output)))
    temp=mktempdir(dirname(abspath(output));prefix="group-transport-")
    try
        CSV.write(joinpath(temp,"mapping.csv"),mapping)
        CSV.write(joinpath(temp,"sources.csv"),sources)
        CSV.write(joinpath(temp,"targets.csv"),targets)
        CSV.write(joinpath(temp,"target-quality.csv"),target_quality)
        open(io->JSON.print(io,metadata,2),joinpath(temp,"manifest.json"),"w")
        mv(temp,output)
    finally
        ispath(temp) && rm(temp;recursive=true)
    end
    println(JSON.json(metadata))
end
end

if abspath(PROGRAM_FILE) == @__FILE__
    5 <= length(ARGS) <= 6 || error("usage: group_transport.jl SOURCES.arrow INPUT_DIR LAYOUT_DIR NEW_OUTPUT RESOLUTION [grouped|pooled]")
    mode=length(ARGS)==6 ? ARGS[6] : "grouped"
    mode in ("grouped","pooled") || error("unknown transport mode")
    IslandTransport.run(ARGS[1:4]...,parse(Int,ARGS[5]);pooled=mode=="pooled")
end
