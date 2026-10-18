"""One source component or target piece, in north-positive coordinates."""
struct Piece
    id::String
    mass::Float64
    centre::NTuple{2,Float64}
    bounds::NTuple{4,Float64}
    function Piece(id, mass, centre, bounds)
        mass > 0 && isfinite(mass) || throw(ArgumentError("Mass must be positive and finite"))
        all(isfinite, centre) && all(isfinite, bounds) || throw(ArgumentError("Invalid coordinates"))
        bounds[1] <= bounds[3] && bounds[2] <= bounds[4] || throw(ArgumentError("Invalid bounds"))
        new(string(id), mass, Tuple(Float64.(centre)), Tuple(Float64.(bounds)))
    end
end

# Rectangular shortest-augmenting-path assignment. Columns and rows are visited
# in stable order; exact ties keep the first candidate. There is no random seed.
function assignment(cost::Matrix{Float64})
    n, m = size(cost)
    n <= m || throw(ArgumentError("Need at least as many columns as rows"))
    all(isfinite, cost) || throw(ArgumentError("Costs must be finite"))
    u = zeros(n); v = zeros(m + 1); p = zeros(Int, m + 1); way = zeros(Int, m + 1)
    for i in 1:n
        p[1] = i; j0 = 1
        distance = fill(Inf, m + 1); used = falses(m + 1)
        while true
            used[j0] = true; i0 = p[j0]; delta = Inf; j1 = 0
            for j in 2:m+1
                used[j] && continue
                reduced = cost[i0, j-1] - u[i0] - v[j]
                if reduced < distance[j]
                    distance[j] = reduced; way[j] = j0
                end
                if distance[j] < delta
                    delta = distance[j]; j1 = j
                end
            end
            for j in 1:m+1
                if used[j]
                    u[p[j]] += delta; v[j] -= delta
                else
                    distance[j] -= delta
                end
            end
            j0 = j1
            p[j0] == 0 && break
        end
        while j0 != 1
            j1 = way[j0]; p[j0] = p[j1]; j0 = j1
        end
    end
    result = zeros(Int, n)
    for j in 2:m+1
        p[j] != 0 && (result[p[j]] = j - 1)
    end
    result
end

function extent(pieces)
    (minimum(p.bounds[1] for p in pieces), minimum(p.bounds[2] for p in pieces),
     maximum(p.bounds[3] for p in pieces), maximum(p.bounds[4] for p in pieces))
end

"""Joint position/population baseline. No reviewed identities enter this function.

Returns candidate identities, not approved population assignments. Dummy columns
leave surplus target pieces unmatched. Scores are costs, not probabilities.
"""
function match_identities(sources, targets; population_weight=0.035, relationship_weight=0.05)
    all(w -> isfinite(w) && w >= 0, (population_weight, relationship_weight)) || throw(ArgumentError("Invalid weight"))
    s = sort(collect(sources); by=p -> p.id); t = sort(collect(targets); by=p -> p.id)
    length(unique(p.id for p in s)) == length(s) || throw(ArgumentError("Duplicate source IDs"))
    length(unique(p.id for p in t)) == length(t) || throw(ArgumentError("Duplicate target IDs"))
    isempty(t) && return NamedTuple[]
    isempty(s) && throw(ArgumentError("No source components"))
    total = sum(p.mass for p in t); source_total = sum(p.mass for p in s)
    isfinite(total) && isfinite(source_total) || throw(ArgumentError("Population total overflow"))
    quota = [p.mass / source_total * total for p in s]
    significant = findall(>=(0.25), quota)
    isempty(significant) && push!(significant, argmax(quota))
    sb = extent(s[significant]); tb = extent(t)
    scale = ntuple(a -> max(tb[a+2]-tb[a], 1) / max(sb[a+2]-sb[a], 1e-6), 2)
    span = ntuple(a -> max(tb[a+2]-tb[a], 4), 2)
    mapped = [ntuple(a -> tb[a] + (p.centre[a]-sb[a])*scale[a], 2) for p in s]
    position = [sum(((p.centre[a]-q[a])/span[a])^2 for a in 1:2) for p in t, q in mapped]
    sizecost = [abs(log(p.mass / max(q, 0.25))) for p in t, q in quota]
    cost = position + population_weight * sizecost
    # Dummies are only needed when there are more targets than sources. The
    # constant penalty makes the solver use all real sources before a dummy.
    dummy = fill(maximum(cost) + 1, length(t), max(0, length(t)-length(s)))
    chosen = assignment(hcat(cost, dummy))
    # Refine joint assignments with relative direction. A country-wide position
    # scale otherwise loses the order of two nearby islands in a remote group.
    # This is deterministic pair-swap descent, not a global quadratic optimum.
    function relation(i, j, a, b)
        (a > length(s) || b > length(s)) && return 0.0
        dx = ntuple(k -> (t[i].centre[k]-t[j].centre[k])/span[k], 2)
        dy = ntuple(k -> (mapped[a][k]-mapped[b][k])/span[k], 2)
        norm = sqrt(sum(abs2,dx)*sum(abs2,dy))
        norm <= eps(Float64) && return 0.0
        relationship_weight * (1-clamp(sum(dx[k]*dy[k] for k in 1:2)/norm,-1,1))/2
    end
    fullcost = hcat(cost,dummy)
    while true
        best = -1e-12; swap = nothing
        for i in 1:length(t), j in i+1:length(t)
            a,b = chosen[i],chosen[j]
            delta = fullcost[i,b]+fullcost[j,a]-fullcost[i,a]-fullcost[j,b]
            delta += relation(i,j,b,a)-relation(i,j,a,b)
            for k in eachindex(t)
                (k == i || k == j) && continue
                c = chosen[k]
                delta += relation(i,k,b,c)+relation(j,k,a,c)-relation(i,k,a,c)-relation(j,k,b,c)
            end
            if delta < best
                best = delta; swap = (i,j)
            end
        end
        isnothing(swap) && break
        i,j = swap; chosen[i],chosen[j] = chosen[j],chosen[i]
    end
    [begin
        j = chosen[i]
        if j > length(s)
            (target_id=p.id, source_id="", position_cost=NaN, population_cost=NaN, relationship_cost=NaN, cost=NaN)
        else
            relational = sum((relation(i,k,j,chosen[k])/2 for k in eachindex(t) if k != i); init=0.0)
            (target_id=p.id, source_id=s[j].id, position_cost=position[i,j],
             population_cost=sizecost[i,j], relationship_cost=relational, cost=cost[i,j]+relational)
        end
    end for (i,p) in enumerate(t)]
end
