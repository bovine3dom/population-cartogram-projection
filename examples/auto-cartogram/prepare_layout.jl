#!/usr/bin/env julia

module LayoutInputs
using CSV, DataFrames, JSON, SHA
include("prepare_world.jl")
const Audit = WorldComponents.IslandAudit

# Equal Earth, EPSG method 1078. Units are arbitrary; the generator rescales area.
function project(lon, lat)
    theta = asin(sqrt(3) / 2 * sin(deg2rad(lat)))
    a1, a2, a3, a4 = 1.340264, -0.081106, 0.000893, 0.003796
    x = 2sqrt(3) * deg2rad(lon) * cos(theta) /
        (3 * (a1 + 3a2*theta^2 + theta^6 * (7a3 + 9a4*theta^2)))
    y = theta * (a1 + a2*theta^2 + theta^6 * (a3 + a4*theta^2))
    return (x,y)
end

function budgets(populations, ids, n; minimum=0)
    n >= minimum * length(ids) || error("tile budget is below the required minimum")
    ideal, counts = Audit.tile_budgets(populations, ids, n)
    counts = max.(counts, minimum)
    while sum(counts) > n
        donors = findall(>(minimum), counts)
        i = first(sort(donors; by=i -> (-(counts[i]-ideal[i]), ids[i])))
        counts[i] -= 1
    end
    return counts
end

function groups(components, populations, n; policy="group")
    policy in ("group", "omit") || error("unknown small-island policy")
    ids = [c.component_id for c in components]
    countries = sort!(unique(c.country_id for c in components))
    members = [findall(c -> c.country_id == country, components) for country in countries]
    if policy == "omit"
        _, counts = Audit.tile_budgets(populations, ids, n)
        return counts, collect(eachindex(ids)), copy(populations)
    end
    national = budgets([sum(populations[m]) for m in members], countries, n; minimum=1)
    counts = zeros(Int,length(ids)); anchor = collect(eachindex(ids)); mass = zeros(length(ids))
    for (m, target) in zip(members, national)
        _, initial = Audit.tile_budgets(populations[m], ids[m], target)
        live = m[initial .> 0]
        for i in m
            # Nearest represented component of the SAME Natural Earth country.
            # The spherical distance proxy respects the longitude seam.
            lon = (components[i].west + components[i].east)/2
            lat = (components[i].south + components[i].north)/2
            distance(j) = begin
                otherlon = (components[j].west + components[j].east)/2
                otherlat = (components[j].south + components[j].north)/2
                sin(deg2rad(lat-otherlat)/2)^2 + cosd(lat)*cosd(otherlat)*sin(deg2rad(lon-otherlon)/2)^2
            end
            a = i in live ? i : first(sort(live; by=j -> (distance(j),ids[j])))
            anchor[i] = a
            mass[a] += populations[i]
        end
        counts[live] = budgets(mass[live], ids[live], target; minimum=1)
    end
    return counts, anchor, mass
end

# Douglas-Peucker on a chain. Shared boundary vertices are protected separately.
function simplify_chain(points, tolerance)
    length(points) <= 2 && return points
    a, b = first(points), last(points)
    dx, dy = b[1]-a[1], b[2]-a[2]
    d2 = dx^2 + dy^2
    distance(p) = d2 == 0 ? hypot(p[1]-a[1],p[2]-a[2]) :
        abs(dy*p[1]-dx*p[2]+b[1]*a[2]-b[2]*a[1])/sqrt(d2)
    distances = distance.(points[2:end-1])
    value, at = findmax(distances)
    value <= tolerance && return [a,b]
    at += 1
    return vcat(simplify_chain(points[1:at],tolerance)[1:end-1],
                simplify_chain(points[at:end],tolerance))
end

function outline(ring, shared; tolerance=0.0003)
    points = [project(p...) for p in ring[1:end-1]]
    # Always keep three well-separated vertices to avoid a collapsed ring.
    anchors = sort!(unique(vcat([1, max(2,cld(length(points),3)), max(3,cld(2length(points),3))],
        findall(p -> get(shared,Tuple(p),0)>1, ring[1:end-1]))))
    result = Tuple{Float64,Float64}[]
    for (a,b) in zip(anchors, vcat(anchors[2:end],length(points)+1))
        chain = b <= length(points) ? points[a:b] : vcat(points[a:end],[points[1]])
        append!(result, simplify_chain(chain,tolerance)[1:end-1])
    end
    length(result) >= 3 || error("simplified polygon collapsed")
    area = sum(result[i][1]*result[mod1(i+1,length(result))][2] -
        result[mod1(i+1,length(result))][1]*result[i][2] for i in eachindex(result))
    area < 0 && reverse!(result)
    return result
end

function geographic_contacts(components)
    segments = Dict{Tuple{Tuple{Float64,Float64},Tuple{Float64,Float64}},Vector{Int}}()
    for (i,c) in enumerate(components), ring in c.rings
        for (a,b) in zip(ring[1:end-1],ring[2:end])
            p, q = Tuple(Float64.(a)), Tuple(Float64.(b))
            p == q && continue
            edge = p < q ? (p,q) : (q,p)
            push!(get!(segments,edge,Int[]),i)
        end
    end
    contacts = Set{Tuple{Int,Int}}()
    for owners in values(segments)
        sort!(unique!(owners))
        for i in 1:length(owners), j in i+1:length(owners)
            push!(contacts,(owners[i],owners[j]))
        end
    end
    return sort!(collect(contacts))
end

function run(summary_path, boundary_path, output, n; country="world", policy="group")
    ispath(output) && error("refusing to overwrite $output")
    summary = CSV.read(summary_path,DataFrame)
    by_hash = Dict(last(split(r.component_id,':')) => r.population for r in eachrow(summary))
    length(by_hash) == nrow(summary) || error("ambiguous polygon hashes")
    all_components = WorldComponents.polygons(JSON.parsefile(boundary_path))
    components = [c for c in all_components if (country=="world" || c.country_id==country) &&
        get(by_hash,last(split(c.component_id,':')),0.0)>0]
    isempty(components) && error("no populated components")
    populations = [by_hash[last(split(c.component_id,':'))] for c in components]
    counts, anchor, masses = groups(components,populations,n;policy)
    live = findall(>(0),counts)
    shared = Dict{Tuple{Float64,Float64},Int}()
    for c in components, ring in c.rings, p in unique(Tuple.(ring))
        shared[p] = get(shared,p,0)+1
    end
    input_contacts = geographic_contacts(components)
    represented = Set(live)
    rows = [(;component_id=c.component_id, country_id=c.country_id, name=c.name,
        population=populations[i], group_id=components[anchor[i]].component_id,
        grouped=i!=anchor[i], tiles=counts[i], group_population=masses[i],
        holes=length(c.rings)-1, west=c.west,east=c.east,south=c.south,north=c.north)
        for (i,c) in enumerate(components)]
    manifest = Dict("country"=>country,"tile_budget"=>n,"policy"=>policy,
        "population_total"=>sum(populations), "represented_population"=>sum(masses[live]),
        "omitted_population"=>sum(populations)-sum(masses[live]),
        "grouped_population"=>sum(populations[i] for i in eachindex(anchor) if anchor[i]!=i;init=0.0),
        "input_components"=>length(components),"represented_shapes"=>length(live),
        "represented_countries"=>length(unique(components[i].country_id for i in live)),
        "holes_not_encoded_in_wkt"=>sum(length(components[i].rings)-1 for i in live),
        "projection"=>"Equal Earth (EPSG method 1078)","simplification_tolerance"=>0.0003,
        "country_identity"=>"Natural Earth ADM0_A3; no synthetic ISO numeric codes",
        "group_policy"=>policy=="group" ? "country minimum 1 tile, then zero-budget components join nearest represented component of same country; reallocate within country" : "global largest remainder; zero-budget components are omitted and their population is reported",
        "geometry_limit"=>"WKT supports outer rings only; hole-border contacts are audited separately",
        "inputs"=>[Dict("path"=>abspath(p),"sha256"=>Audit.file_hash(p)) for p in (summary_path,boundary_path,@__FILE__)])
    mkpath(dirname(abspath(output)))
    temp = mktempdir(dirname(abspath(output));prefix="layout-input-")
    try
        CSV.write(joinpath(temp,"groups.csv"),DataFrame(rows))
        contacts = DataFrame(a=String[],b=String[],both_represented=Bool[])
        for (a,b) in input_contacts
            push!(contacts,(components[a].component_id,components[b].component_id,a in represented && b in represented))
        end
        CSV.write(joinpath(temp,"geographic-contacts.csv"),contacts)
        open(joinpath(temp,"input.wkt"),"w") do io
            println(io,"STAGE 1\nOUTLINES $(length(live))")
            for (index,i) in enumerate(live)
                c=components[i]
                points=outline(first(c.rings),shared)
                x=sum(first,points)/length(points); y=sum(last,points)/length(points)
                println(io,"OUT $(index-1)\t$(c.component_id)\t$x $y\t100 160 210")
                println(io,join(["$(p[1]) $(p[2])" for p in points],'\t'))
                println(io,"SITECOUNT 0")
            end
        end
        open(joinpath(temp,"weights.tsv"),"w") do io
            for i in live
                println(io,"$(components[i].component_id)\t$(counts[i])")
            end
        end
        open(io->JSON.print(io,manifest,2),joinpath(temp,"manifest.json"),"w")
        mv(temp,output)
    finally
        ispath(temp) && rm(temp;recursive=true)
    end
    println("Wrote $output: $(length(live)) shapes, $n tiles, $(manifest["grouped_population"]) grouped people")
end
end

if abspath(PROGRAM_FILE) == @__FILE__
    4 <= length(ARGS) <= 6 || error("usage: prepare_layout.jl COMPONENTS.csv BOUNDARY.geojson NEW_DIR TILES [COUNTRY_ID=world] [group|omit]")
    LayoutInputs.run(ARGS[1:3]...,parse(Int,ARGS[4]);country=length(ARGS)>=5 ? ARGS[5] : "world",
        policy=length(ARGS)>=6 ? ARGS[6] : "group")
end
