const ALIASES = Dict("SDS" => "SSD", "PSX" => "PSE", "SAH" => "ESH")

function code_table(path)
    Dict(String(r.alpha3) => parse(Int, r.numeric) for r in CSV.File(path; types=String))
end

function connected_parts(points)
    remaining = Set(points); result = Set{Tuple{Int,Int}}[]
    while !isempty(remaining)
        seed = minimum(remaining); delete!(remaining, seed)
        part = Set([seed]); queue = [seed]
        for (x,y) in queue
            for q in ((x-1,y), (x+1,y), (x,y-1), (x,y+1))
                if q in remaining
                    delete!(remaining, q); push!(part, q); push!(queue, q)
                end
            end
        end
        push!(result, part)
    end
    sort!(result; by=p -> (-length(p), minimum(p)))
end

"""Read the original OWID lattice. Duplicate coordinates use the last row."""
function read_targets(path, codes)
    rows = collect(CSV.File(path; header=[:x,:y,:code], types=Int))
    isempty(rows) && throw(ArgumentError("Empty OWID input"))
    xs = sort!(unique(r.x for r in rows)); ys = sort!(unique(r.y for r in rows))
    step = foldl(gcd, vcat(diff(xs), diff(ys)); init=0)
    step = max(step, 1)
    reverse = Dict(v => k for (k,v) in codes)
    owner = Dict(((r.x-first(xs))÷step, -(r.y-first(ys))÷step) => r.code for r in rows)
    grouped = Dict{String,Vector{Piece}}()
    for code in sort!(unique(collect(values(owner))))
        scope = get(reverse, code, "OWID_$code")
        pieces = Piece[]
        for (i, cells) in enumerate(connected_parts(p for (p,c) in owner if c == code))
            points = sort!(collect(cells))
            centre = ntuple(a -> sum(p[a] for p in points)/length(points), 2)
            bounds = (minimum(first, points)-0.5, minimum(last, points)-0.5,
                      maximum(first, points)+0.5, maximum(last, points)+0.5)
            push!(pieces, Piece("$scope:T$i", length(points), centre, bounds))
        end
        grouped[scope] = pieces
    end
    grouped
end

# Use all polygon rings for the centroid. Holes subtract area regardless of
# winding. Longitude wrapping is centred on the largest populated component.
function geometry_descriptor(geometry, longitude, latitude)
    polygons = geometry["type"] == "Polygon" ? [geometry["coordinates"]] :
               geometry["type"] == "MultiPolygon" ? geometry["coordinates"] :
               throw(ArgumentError("Expected polygon geometry"))
    points = Tuple{Float64,Float64}[]; area = 0.0; mx = 0.0; my = 0.0
    for polygon in polygons
        for (r, ring) in enumerate(polygon)
            xy = [(mod(Float64(p[1])-longitude+180, 360)-180,
                   Float64(p[2])-latitude) for p in ring]
            append!(points, xy)
            twice_area = 0.0; cx = 0.0; cy = 0.0
            for i in eachindex(xy)
                a = xy[i]; b = xy[mod1(i+1,length(xy))]
                cross = a[1]*b[2]-b[1]*a[2]
                twice_area += cross; cx += (a[1]+b[1])*cross; cy += (a[2]+b[2])*cross
            end
            twice_area == 0 && continue
            weight = (r == 1 ? 1 : -1) * abs(twice_area)/2
            area += weight; mx += weight*cx/(3*twice_area); my += weight*cy/(3*twice_area)
        end
    end
    area > 0 || throw(ArgumentError("Non-positive polygon area"))
    (mx/area, my/area), (minimum(first,points), minimum(last,points),
                       maximum(first,points), maximum(last,points))
end

"""Read existing Natural Earth/Kontur component intermediates; no identity table."""
function read_sources(components, polygons, codes)
    rows = collect(CSV.File(components; types=String))
    features = JSON.parsefile(polygons)["features"]
    geometry = Dict(String(f["properties"]["component_id"]) => f["geometry"] for f in features)
    grouped = Dict{String,Vector{Piece}}()
    scopes = Dict{String,Vector{Int}}()
    for (i,r) in enumerate(rows)
        population = parse(Float64,r.population)
        isfinite(population) && population >= 0 || throw(ArgumentError("Invalid population"))
        population == 0 && continue
        scope = String(haskey(codes,r.map_unit) ? r.map_unit : r.country_id)
        scope = get(ALIASES,scope,scope)
        push!(get!(scopes,scope,Int[]),i)
    end
    for scope in sort!(collect(keys(scopes)))
        indices = sort(scopes[scope]; by=i -> (-parse(Float64,rows[i].population), rows[i].component_id))
        anchor = rows[first(indices)]
        lon = (parse(Float64,anchor.west)+parse(Float64,anchor.east))/2
        lat = (parse(Float64,anchor.south)+parse(Float64,anchor.north))/2
        pieces = Piece[]
        for i in indices
            r = rows[i]; centre,bounds = geometry_descriptor(geometry[r.component_id],lon,lat)
            push!(pieces, Piece(r.component_id,parse(Float64,r.population),centre,bounds))
        end
        grouped[scope] = pieces
    end
    grouped
end
