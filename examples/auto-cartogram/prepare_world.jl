#!/usr/bin/env julia

# Build stable Natural Earth polygon identities. Keep raw map-unit identity:
# ISO_N3_EH is not a reliable globally unique country identifier in this snapshot.
module WorldComponents
using JSON, SHA
include("audit.jl")

function polygons(boundary)
    result = NamedTuple[]
    for feature in boundary["features"]
        p = feature["properties"]
        g = feature["geometry"]
        g["type"] in ("Polygon", "MultiPolygon") || error("unsupported geometry")
        parts = g["type"] == "Polygon" ? [g["coordinates"]] : g["coordinates"]
        for rings in parts
            id = string(p["GU_A3"], ":", bytes2hex(sha256(JSON.json(rings)))[1:16])
            xs = first.(first(rings)); ys = last.(first(rings))
            push!(result, (; component_id=id, country_id=String(p["ADM0_A3"]),
                map_unit=String(p["GU_A3"]), name=String(p["NAME"]),
                raw_country_code=string(p["ISO_N3_EH"]), rings,
                west=minimum(xs), east=maximum(xs), south=minimum(ys), north=maximum(ys)))
        end
    end
    allunique(c.component_id for c in result) || error("duplicate component identity")
    return sort!(result; by=c -> c.component_id)
end

end
