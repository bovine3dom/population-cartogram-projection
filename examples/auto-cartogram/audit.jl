#!/usr/bin/env julia

module IslandAudit

using Arrow, CSV, DataFrames, H3, JSON, SHA
include(joinpath(@__DIR__, "..", "..", "scripts", "extract_kontur_country.jl"))

file_hash(path) = open(sha256, path) |> bytes2hex
const OFFSETS = ((-2, 0), (2, 0), (0, -2), (0, 2))

function geographic_components(boundary, country)
    components = NamedTuple[]
    for feature in boundary["features"]
        string(feature["properties"]["ISO_N3_EH"]) == lpad(string(country), 3, '0') || continue
        geometry = feature["geometry"]
        geometry["type"] in ("Polygon", "MultiPolygon") || error("unsupported geometry")
        polygons = geometry["type"] == "Polygon" ? [geometry["coordinates"]] : geometry["coordinates"]
        for rings in polygons
            isempty(rings) && error("empty polygon")
            for ring in rings
                length(ring) >= 4 && first(ring) == last(ring) || error("ring is not closed")
                all(p -> length(p) == 2 && all(isfinite, p) &&
                    -180 <= p[1] <= 180 && -90 <= p[2] <= 90, ring) || error("invalid coordinates")
            end
            xs = first.(first(rings)); ys = last.(first(rings))
            maximum(xs) - minimum(xs) <= 180 || error("antimeridian repair is required")
            # Stable under feature/polygon reordering, not under geometry edits.
            id = "$country:ne:" * bytes2hex(sha256(JSON.json(rings)))[1:16]
            push!(components, (; component_id=id, rings,
                west=minimum(xs), east=maximum(xs), south=minimum(ys), north=maximum(ys)))
        end
    end
    isempty(components) && error("country has no polygons")
    allunique(c.component_id for c in components) || error("duplicate polygon")
    return sort!(components; by=c -> c.component_id)
end

function geographic_owners(components; resolution=8)
    owners = Dict{UInt64,Int}()
    counts = zeros(Int, length(components))
    for (i, c) in enumerate(components)
        for id in KonturCountryExtract.polygon_cells(c.rings, resolution)
            haskey(owners, id) && error("H3 cell belongs to multiple components: $id")
            owners[id] = i
            counts[i] += 1
        end
    end
    return owners, counts
end

function select_sources(table, owners)
    rows = findall(id -> haskey(owners, id), table.h3)
    isempty(rows) && error("country has no population rows")
    ids = UInt64.(table.h3[rows])
    values = Float64.(table.population[rows])
    allunique(ids) || error("duplicate population H3 IDs")
    all(id -> H3.API.isValidCell(id) && H3.API.getResolution(id) == 8, ids) ||
        error("expected native resolution-8 H3 IDs")
    all(p -> isfinite(p) && p > 0, values) || error("expected positive finite populations")
    return DataFrame(id=ids, value=values, component_index=[owners[id] for id in ids])
end

function target_components(raw, country)
    cells = [(Int(r.x), Int(r.y)) for r in eachrow(raw) if r.country == country]
    isempty(cells) && error("country has no target cells")
    allunique(cells) || error("duplicate target coordinates within country")
    all(p -> all(iseven, p), cells) || error("expected step-2 even-integer square grid")
    # A selected country's targets must not overlap another country's targets.
    selected = Set(cells)
    any(r -> r.country != country && (r.x, r.y) in selected, eachrow(raw)) &&
        error("target ownership overlaps another country")
    remaining = copy(selected)
    components = NamedTuple[]
    while !isempty(remaining)
        seed = minimum(remaining)
        delete!(remaining, seed)
        queue = [seed]
        found = Tuple{Int,Int}[]
        while !isempty(queue)
            x, y = pop!(queue)
            push!(found, (x, y))
            for (dx, dy) in OFFSETS
                p = (x + dx, y + dy)
                if p in remaining
                    delete!(remaining, p)
                    push!(queue, p)
                end
            end
        end
        push!(components, (; target_id="$country:tile:$(seed[1]):$(seed[2])", cells=sort!(found)))
    end
    return components
end

function tile_budgets(populations, ids, total)
    length(populations) == length(ids) && allunique(ids) || error("invalid budget IDs")
    total >= 0 && all(p -> isfinite(p) && p >= 0, populations) && sum(populations) > 0 ||
        error("invalid budget inputs")
    ideal = total .* (populations ./ sum(populations))
    counts = floor.(Int, ideal)
    order = sortperm(eachindex(ids); by=i -> (-(ideal[i] - counts[i]), ids[i]))
    for i in first(order, total - sum(counts))
        counts[i] += 1
    end
    return ideal, counts
end

function resolve_matches(matches, owners, targets)
    resolved = NamedTuple[]
    for row in eachrow(matches)
        row.status in ("reviewed", "provisional") || error("invalid match status")
        isempty(strip(row.evidence)) && error("match needs evidence")
        seed = H3.API.latLngToCell(H3.API.LatLng(deg2rad(row.latitude), deg2rad(row.longitude)), 8)
        haskey(owners, seed) || error("geographic seed outside country: $(row.label)")
        t = findall(c -> (row.target_x, row.target_y) in c.cells, targets)
        length(t) == 1 || error("target seed not found: $(row.label)")
        push!(resolved, (; label=String(row.label), component_index=owners[seed],
            target_index=only(t), status=String(row.status), evidence=String(row.evidence)))
    end
    allunique(r.label for r in resolved) || error("duplicate match label")
    allunique(r.component_index for r in resolved) || error("geographic component matched twice")
    allunique(r.target_index for r in resolved) || error("target component matched twice")
    return resolved
end

function capacity_audit(populations, counts, matches)
    total_population, total_tiles = sum(populations), sum(counts)
    total_population > 0 && total_tiles > 0 || error("empty audit")
    rows = NamedTuple[]
    for r in matches
        r.status == "reviewed" || continue
        push!(rows, (; group=r.label, population=populations[r.component_index],
            tiles=counts[r.target_index]))
    end
    # Pool all unresolved islands on BOTH sides. This gives a coarse lower bound,
    # not an assertion that they form one island or should share a transport solve.
    push!(rows, (; group="unmatched-remainder",
        population=total_population - sum((r.population for r in rows); init=0.0),
        tiles=total_tiles - sum((r.tiles for r in rows); init=0)))
    result = DataFrame(rows)
    result.population_share = result.population ./ total_population
    result.tile_share = result.tiles ./ total_tiles
    result.capacity = total_population .* result.tile_share
    result.excess_population = result.capacity .- result.population
    result.excess_share = result.tile_share .- result.population_share
    lower_bound = length(rows) == 1 ? nothing : sum(abs, result.excess_population) / 2
    return result, lower_bound
end

escape_xml(s) = replace(string(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")
color(i) = "hsl($(mod(137i, 360)),55%,68%)"

function overview(path, components, targets, matches, raw, country)
    source_labels = Dict(r.component_index => r.label for r in matches)
    target_labels = Dict(r.target_index => r.label for r in matches)
    match_colors = Dict(r.label => color(i) for (i, r) in enumerate(matches))
    # Both panels are diagnostics, not map projections for area measurement.
    west = minimum(c.west for c in components); east = maximum(c.east for c in components)
    north = maximum(c.north for c in components); south = minimum(c.south for c in components)
    points = reduce(vcat, [t.cells for t in targets])
    xmin, xmax = extrema(first.(points)); ymin, ymax = extrema(last.(points))
    scale_geo = min(1120 / (east - west), 330 / (north - south))
    # Include neighbouring countries so shared-island matches can be reviewed.
    xmin -= 4; xmax += 20; ymin -= 4; ymax += 4
    scale_grid = min(1120 / (xmax - xmin + 2), 330 / (ymax - ymin + 2))
    gx(x) = 40 + (x - west) * scale_geo
    gy(y) = 65 + (north - y) * scale_geo
    tx(x) = 40 + (x - xmin + 1) * scale_grid
    ty(y) = 505 + (y - ymin + 1) * scale_grid
    open(path, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 900">
        <rect width="1200" height="900" fill="white"/>
        <g font-family="sans-serif" font-size="13">
        <text x="40" y="28" font-size="21">Geographic components: country $country</text>
        <text x="40" y="48">Longitude/latitude view. Gray components are not matched. Ring points are sampled for this preview only.</text>""")
        for (i, c) in enumerate(components)
            label = get(source_labels, i, "")
            fill = get(match_colors, label, "#ccc")
            paths = String[]
            for ring in c.rings
                step = max(1, cld(length(ring), 250))
                push!(paths, "M " * join(["$(gx(p[1])),$(gy(p[2]))" for p in ring[1:step:end]], " L ") * " Z")
            end
            println(io, "<path d=\"$(join(paths, " "))\" fill=\"$fill\" fill-rule=\"evenodd\" stroke=\"#777\" stroke-width=\"0.4\"><title>$(escape_xml(c.component_id))</title></path>")
            isempty(label) || println(io, "<text x=\"$(gx((c.west+c.east)/2))\" y=\"$(gy((c.north+c.south)/2))\" text-anchor=\"middle\">$(escape_xml(label))</text>")
        end
        println(io, "<text x=\"40\" y=\"460\" font-size=\"21\">Existing OWID targets: side-connected components</text>")
        println(io, "<text x=\"40\" y=\"482\">Matched colors follow the review table, not an automatic geographic assignment. Other countries are pale gray.</text>")
        for r in eachrow(raw)
            if r.country != country && xmin <= r.x <= xmax && ymin <= r.y <= ymax
                println(io, "<rect x=\"$(tx(r.x-1))\" y=\"$(ty(r.y-1))\" width=\"$(2scale_grid)\" height=\"$(2scale_grid)\" fill=\"#eee\"/>")
            end
        end
        for (i, t) in enumerate(targets)
            label = get(target_labels, i, "")
            fill = get(match_colors, label, "#bbb")
            for (x, y) in t.cells
                println(io, "<rect x=\"$(tx(x-1))\" y=\"$(ty(y-1))\" width=\"$(2scale_grid)\" height=\"$(2scale_grid)\" fill=\"$fill\" stroke=\"white\" stroke-width=\"0.25\"><title>$(t.target_id): $x,$y</title></rect>")
            end
            x = sum(first, t.cells) / length(t.cells)
            y = sum(last, t.cells) / length(t.cells)
            text = isempty(label) ? string(i) : label
            println(io, "<text x=\"$(tx(x))\" y=\"$(ty(y))\" text-anchor=\"middle\">$(escape_xml(text)) ($(length(t.cells)))</text>")
        end
        println(io, "</g></svg>")
    end
end

function run(population_path, boundary_path, cartogram_path, output; country=360, matches_path=nothing)
    ispath(output) && error("refusing to overwrite $output")
    started = time()
    components = geographic_components(JSON.parsefile(boundary_path), country)
    println("Filling $(length(components)) geographic polygons at H3-8")
    owners, boundary_counts = geographic_owners(components)
    sources = select_sources(Arrow.Table(population_path), owners)
    raw = CSV.read(cartogram_path, DataFrame; header=[:x, :y, :country], types=Int)
    targets = target_components(raw, country)
    matches = isnothing(matches_path) ? NamedTuple[] : resolve_matches(
        CSV.read(matches_path, DataFrame; types=Dict(:label=>String, :status=>String, :evidence=>String)), owners, targets)
    populations = zeros(Float64, length(components))
    source_counts = zeros(Int, length(components))
    boundary_population = zeros(Float64, length(components))
    for r in eachrow(sources)
        i = r.component_index
        populations[i] += r.value
        source_counts[i] += 1
        # This is a review flag, not an error estimate. It includes land borders.
        if any(n -> !iszero(n) && get(owners, n, 0) != i, H3.API.gridDisk(r.id, 1))
            boundary_population[i] += r.value
        end
    end
    counts = [length(t.cells) for t in targets]
    ids = [c.component_id for c in components]
    ideal, budgets = tile_budgets(populations, ids, sum(counts))
    component_table = DataFrame(component_id=ids, country_code=country,
        population=populations, source_cells=source_counts, boundary_cells=boundary_counts,
        boundary_sensitive_population=boundary_population,
        west=[c.west for c in components], east=[c.east for c in components],
        south=[c.south for c in components], north=[c.north for c in components],
        ideal_tiles=ideal, allocated_tiles=budgets,
        label=fill("", length(components)), match_status=fill("unmatched", length(components)))
    target_table = DataFrame(target_id=[t.target_id for t in targets], tiles=counts,
        seed_x=[first(t.cells)[1] for t in targets], seed_y=[first(t.cells)[2] for t in targets],
        label=fill("", length(targets)), match_status=fill("unmatched", length(targets)))
    for r in matches
        component_table.label[r.component_index] = r.label
        component_table.match_status[r.component_index] = r.status
        target_table.label[r.target_index] = r.label
        target_table.match_status[r.target_index] = r.status
    end
    comparison, lower_bound = capacity_audit(populations, counts, matches)
    sources.component_id = ids[sources.component_index]
    sources.country_code = fill(country, nrow(sources))
    select!(sources, :id, :value, :country_code, :component_id)
    sort!(sources, :id)
    manifest = Dict(
        "country_code"=>country, "source_resolution"=>8, "grid_step"=>2,
        "population_total"=>sum(populations), "source_cells"=>nrow(sources),
        "geographic_components"=>length(components), "target_components"=>length(targets),
        "target_tiles"=>sum(counts), "reviewed_matches"=>count(r -> r.status == "reviewed", matches),
        "coarse_cross_component_lower_bound"=>lower_bound,
        "boundary_sensitive_population"=>sum(boundary_population),
        "positive_components_without_budget"=>count(i -> populations[i]>0 && budgets[i]==0, eachindex(ids)),
        "population_without_budget"=>sum(populations[budgets .== 0]),
        "polygons_without_h3_centres"=>count(iszero, boundary_counts),
        "polygons_without_population"=>count(iszero, populations),
        "population_year"=>"unknown: input Arrow has no declared year",
        "membership"=>"H3-8 cell centre in a supplied polygon, outside its holes; no coastal splitting",
        "component_identity"=>"country plus SHA-256 prefix of polygon coordinate JSON; geometry edits change IDs",
        "unmatched_policy"=>"pool unreviewed sources and targets only for the coarse lower bound",
        "julia_version"=>string(VERSION),
        "inputs"=>[Dict("role"=>role, "path"=>abspath(path), "sha256"=>file_hash(path))
            for (role,path) in [("population",population_path), ("boundary",boundary_path),
                ("cartogram",cartogram_path), ("script",@__FILE__),
                ("extractor",joinpath(@__DIR__, "..", "..", "scripts", "extract_kontur_country.jl")),
                ("environment",joinpath(@__DIR__, "Manifest.toml"))]])
    isnothing(matches_path) || push!(manifest["inputs"], Dict("role"=>"matches", "path"=>abspath(matches_path), "sha256"=>file_hash(matches_path)))
    # Publish only after all calculations and writes succeed.
    mkpath(dirname(abspath(output)))
    temporary = mktempdir(dirname(abspath(output)); prefix="island-audit-")
    try
        CSV.write(joinpath(temporary, "components.csv"), component_table)
        CSV.write(joinpath(temporary, "targets.csv"), target_table)
        CSV.write(joinpath(temporary, "capacity.csv"), comparison)
        Arrow.write(joinpath(temporary, "source-components.arrow"), sources)
        overview(joinpath(temporary, "overview.svg"), components, targets, matches, raw, country)
        manifest["elapsed_seconds"] = time() - started
        open(io -> JSON.print(io, manifest, 2), joinpath(temporary, "manifest.json"), "w")
        mv(temporary, output)
    finally
        ispath(temporary) && rm(temporary; recursive=true)
    end
    println("Population: $(sum(populations)); targets: $(sum(counts)); lower bound: $lower_bound")
    println("Wrote $output")
    return manifest
end

function main(args=ARGS)
    4 <= length(args) <= 6 || error("usage: audit.jl POPULATION.arrow BOUNDARY.geojson CARTOGRAM.csv NEW_OUTPUT_DIR [COUNTRY=360] [MATCHES.csv]")
    run(args[1:4]...; country=length(args)>=5 ? parse(Int,args[5]) : 360,
        matches_path=length(args)==6 ? args[6] : nothing)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    IslandAudit.main()
end
