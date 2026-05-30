#!/bin/julia
using CSV, DataFrames, Luxor, Arrow, ThreadsX, StatsBase, ColorSchemes
import H3
import Colors: RGB

cartogram = CSV.read("../data/cartogram.csv", DataFrame, header=false)
rename!(cartogram, [:x, :y, :code])
countries = CSV.read("../data/country-code.csv", DataFrame)
country_colours = Dict(c => rand(3) for c in unique(cartogram.code))

function render_cartogram(
    cartogram; 
    legend = z -> RGB(get(country_colours, z, 0)...), # lookup function data -> colour
    field::Symbol = :code,
    square_size::Real=10,
    draw_outline::Bool=true,
    outline_color::String="black",
    outline_width::Real=0.5,
    padding::Real=20,
    filename::String="hello.png",
    font_size::Real=8,
    font_face::String="Iosevka",
    text_color::String="black"
)
    min_x, max_x = minimum(cartogram.x), maximum(cartogram.x)
    min_y, max_y = minimum(cartogram.y), maximum(cartogram.y)
    
    width = Int(ceil((max_x - min_x + 1) * square_size + 2 * padding)/2)
    height = Int(ceil((max_y - min_y + 1) * square_size + 2 * padding)/2)
    
    Drawing(width, height, filename)
    
    origin() 
    background("white")
    
    center_x = (min_x + max_x) / 2
    center_y = (min_y + max_y) / 2
    
    for row in eachrow(cartogram)
        cx = (row.x - center_x) * square_size/2
        cy = (row.y - center_y) * square_size/2
        
        sethue(legend(row[field]))
        box(Point(cx, cy), square_size, square_size, :fill)
        
        if draw_outline
            sethue(outline_color)
            setline(outline_width)
            box(Point(cx, cy), square_size, square_size, :stroke)
        end
    end
    
    if "label" in names(cartogram)
        fontsize(font_size)
        fontface(font_face)
        
        for row in eachrow(cartogram)
            val = row.label
            
            if !ismissing(val)
                println(val)
                cx = (row.x - center_x) * square_size/2
                cy = (row.y - center_y) * square_size/2
                sethue("white")
                setline(5)
                textoutlines(string(val), Point(cx, cy), :stroke, halign=:center, valign=:middle)
                sethue(text_color)
                text(string(val), Point(cx, cy), halign=:center, valign=:middle)
            end
        end
    end
    
    finish()
end

function subdivide_cartogram(df::DataFrame, n::Int)
    num_orig = nrow(df)
    total_rows = num_orig * n^2
    unique_xs = sort(unique(df.x))
    step_size = length(unique_xs) > 1 ? minimum(diff(unique_xs)) : 1
    new_xs = Vector{Int}(undef, total_rows)
    new_ys = Vector{Int}(undef, total_rows)
    new_codes = Vector{Int}(undef, total_rows)
    xs = df.x
    ys = df.y
    codes = df.code
    
    idx = 1
    for r in 1:num_orig
        x_base = xs[r] * n
        y_base = ys[r] * n
        country_code = codes[r]
        for i in 0:(n-1)
            offset_x = round(Int, (2 * i - n + 1) * step_size / 2)
            for j in 0:(n-1)
                offset_y = round(Int, (2 * j - n + 1) * step_size / 2)
                new_xs[idx] = x_base + offset_x
                new_ys[idx] = y_base + offset_y
                new_codes[idx] = country_code
                idx += 1
            end
        end
    end
    return DataFrame(x = new_xs, y = new_ys, code = new_codes)
end

# european_countries = ["Albania", "Andorra", "Austria", "Belgium", "Bosnia and Herzegovina", "Bulgaria", "Belarus", "Cyprus", "Croatia", "Czechia", "Denmark", "Estonia", "Faeroe Islands", "Finland", "<span data-sort-value=\"Aland Islands !\">Åland Islands", "France", "Germany", "Gibraltar", "Greece", "Hungary", "Iceland", "Ireland", "Italy", "Latvia", "Liechtenstein", "Lithuania", "Luxembourg", "Malta", "Monaco", "Moldova", "Montenegro", "Netherlands", "Norway", "Poland", "Portugal", "Romania", "San Marino", "Serbia", "Slovakia", "Slovenia", "Spain", "Svalbard and Jan Mayen", "Sweden", "Switzerland", "Ukraine", "North Macedonia", "United Kingdom", "Guernsey", "Jersey", "Isle of Man", "Vatican"]
# europe = semijoin(cartogram, countries[in.(countries.name, Ref(european_countries)), :], on=:code)

# ok fun drawing time over. let's do some lookup tables

_population = Arrow.Table("population-data/kontur_population_20231101.arrow") |> DataFrame
country_h3 = Arrow.Table("population-data/country-boundaries/ne_10m_admin_0_map_units.arrow") |> DataFrame
country_h3.ISO_N3_EH = parse.(Int, country_h3.ISO_N3_EH)
rename!(country_h3, :ISO_N3_EH => :code)
leftjoin!(_population, country_h3, on=:h3) # ~70 million missing, <1%. do we care? not sure. we could 'fix' by sorting by h3 then filling the gaps...
population = @view _population[.!ismissing.(_population.code), :]
population.centre = ThreadsX.map(H3.API.cellToLatLng, population.h3)

# for cartogram,
# y increases as latitude decreases
# x increases as longitude increases
# =>
population.x = map(x -> x.lng, population.centre)
population.y = map(x -> -x.lat, population.centre)

sort!(cartogram, [:x, :y])
# sort!(population, [:x, :y])
# gdf[(code,)] # always forget how this indexing works

# can use groupby via combine(groupby(df, :group), d -> addquantiles!(d, :whatever))
"Add [column]_quantile to a dataframe. If jiggle=true, no ties are allowed"
addquantiles!(df, column; jiggle=false) = begin
    if (!jiggle) 
        raw = ecdf(df[!, column]).(df[!, column])
        raw = raw .- minimum(raw)
        raw = raw ./ maximum(raw)
        return df[!, Symbol(string(column) * "_quantile")] = raw
    end
    l = size(df,1)
    tdf = copy(df[!, [column]])
    tdf.id = 1:l
    sort!(tdf, column)
    tdf.q = (1:l)./l
    sort!(tdf, :id)
    return df[!, Symbol(string(column) * "_quantile")] = tdf.q
end

"""
NB `grid_size` must be a power of 2
"""
function xy_to_hilbert(grid_size::Int, x::Int, y::Int)
    d = 0
    s = div(grid_size, 2)
    curr_x = x
    curr_y = y
    while s > 0
        rx = (curr_x & s) > 0 ? 1 : 0
        ry = (curr_y & s) > 0 ? 1 : 0
        d += s * s * ((3 * rx) ^ ry)
        
        if ry == 0
            if rx == 1
                curr_x = grid_size - 1 - curr_x
                curr_y = grid_size - 1 - curr_y
            end
            curr_x, curr_y = curr_y, curr_x
        end
        s = div(s, 2)
    end
    return d
end

function match_h3_to_cartogram(population, cartogram)
    M = size(population, 1)
    N = size(cartogram, 1)
    
    total_pop = sum(population.population)
    target_pop_per_cell = total_pop / N
    grid_size = 2^18
    
    lat_min, lat_max = minimum(population.y), maximum(population.y)
    lon_min, lon_max = minimum(population.x), maximum(population.x)
    
    lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
    lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
    
    x_min, max_x = minimum(cartogram.x), maximum(cartogram.x)
    y_min, max_y = minimum(cartogram.y), maximum(cartogram.y)
    
    x_span = (max_x - x_min) > 0 ? (max_x - x_min) : 1.0
    y_span = (max_y - y_min) > 0 ? (max_y - y_min) : 1.0
    
    pop_hilbert = Vector{Int}(undef, M)
    for i in 1:M
        px = round(Int, (population.x[i] - lon_min) / lon_span * (grid_size - 1))
        py = round(Int, (population.y[i] - lat_min) / lat_span * (grid_size - 1))
        pop_hilbert[i] = xy_to_hilbert(grid_size, px, py)
    end
    
    carto_hilbert = Vector{Int}(undef, N)
    for j in 1:N
        cx = round(Int, (cartogram.x[j] - x_min) / x_span * (grid_size - 1))
        cy = round(Int, (cartogram.y[j] - y_min) / y_span * (grid_size - 1))
        carto_hilbert[j] = xy_to_hilbert(grid_size, cx, cy)
    end
    
    pop_sorted = copy(population)
    pop_sorted.hilbert = pop_hilbert
    sort!(pop_sorted, :hilbert)
    
    carto_sorted = copy(cartogram)
    carto_sorted.hilbert = carto_hilbert
    sort!(carto_sorted, :hilbert)
    
    assigned_h3 = Vector{UInt64}()
    assigned_x = Vector{Int}()
    assigned_y = Vector{Int}()
    assigned_weight = Vector{Float64}()
    assigned_overlap = Vector{Float64}()
    
    pop_idx = 1
    carto_idx = 1
    pop_allocated = 0.0
    cell_allocated = 0.0
    
    p_pop = pop_sorted.population
    p_h3 = pop_sorted.h3
    c_x = carto_sorted.x
    c_y = carto_sorted.y
    
    while pop_idx <= M && carto_idx <= N
        pop_remaining = p_pop[pop_idx] - pop_allocated
        cell_remaining = target_pop_per_cell - cell_allocated
        
        overlap = min(pop_remaining, cell_remaining)
        
        if overlap > 1e-5
            weight = p_pop[pop_idx] > 0 ? (overlap / p_pop[pop_idx]) : 0.0
            push!(assigned_h3, p_h3[pop_idx])
            push!(assigned_x, c_x[carto_idx])
            push!(assigned_y, c_y[carto_idx])
            push!(assigned_weight, weight)
            push!(assigned_overlap, overlap)
        end
        
        pop_allocated += overlap
        cell_allocated += overlap
        
        if pop_allocated >= p_pop[pop_idx] - 1e-5
            pop_idx += 1
            pop_allocated = 0.0
        end
        
        if cell_allocated >= target_pop_per_cell - 1e-5
            carto_idx += 1
            cell_allocated = 0.0
        end
    end
    
    return DataFrame(
        h3 = assigned_h3, 
        x = assigned_x, 
        y = assigned_y, 
        weight = assigned_weight, 
        overlap = assigned_overlap
    )
end

function match_h3_to_cartogram_stripey(population, cartogram)
    N = size(cartogram, 1)
    M = size(population, 1)
    total_pop = sum(population.population)
    target_pop_per_cell = total_pop / N
    pop_idx = 1
    carto_idx = 1
    pop_allocated = 0.0
    cell_allocated = 0.0
    assigned_h3 = Vector{UInt64}()
    assigned_x = Vector{Int}()
    assigned_y = Vector{Int}()
    assigned_weight = Vector{Float64}()
    assigned_overlap = Vector{Float64}()
    sizehint!(assigned_h3, M)
    sizehint!(assigned_x, M)
    sizehint!(assigned_y, M)
    sizehint!(assigned_weight, M)
    sizehint!(assigned_overlap, M)
    while pop_idx <= M && carto_idx <= N
        cell = eachrow(cartogram)[carto_idx]
        pop = eachrow(population)[pop_idx]
        pop_remaining = pop.population - pop_allocated
        cell_remaining = target_pop_per_cell - cell_allocated
        overlap = min(pop_remaining, cell_remaining)
        if overlap > 0.0
            weight = pop.population > 0 ? (overlap / pop.population) : 0.0
            push!(assigned_h3, pop.h3)
            push!(assigned_x, cell.x)
            push!(assigned_y, cell.y)
            push!(assigned_weight, weight)
            push!(assigned_overlap, overlap)
        end
        pop_allocated += overlap
        cell_allocated += overlap
        if pop_allocated >= pop.population
            pop_idx += 1
            pop_allocated = 0.0
        end
        if cell_allocated >= target_pop_per_cell
            carto_idx += 1
            cell_allocated = 0.0
        end
    end
    return DataFrame(h3 = assigned_h3, x = assigned_x, y = assigned_y, weight = assigned_weight, overlap = assigned_overlap)
end

"""
Performs 2D local pairwise swaps to smooth out any boxy "fault lines" 
caused by the 1D space-filling curve approximation.
"""
function relax_assignments_2d(assignments::DataFrame, population::DataFrame, cartogram::DataFrame; passes::Int=2)
    N = nrow(assignments)
    
    lat_min, lat_max = minimum(population.y), maximum(population.y)
    lon_min, lon_max = minimum(population.x), maximum(population.x)
    cx_min, cx_max = minimum(cartogram.x), maximum(cartogram.x)
    cy_min, cy_max = minimum(cartogram.y), maximum(cartogram.y)
    
    lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
    lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
    cx_span = (cx_max - cx_min) > 0 ? (cx_max - cx_min) : 1.0
    cy_span = (cy_max - cy_min) > 0 ? (cy_max - cy_min) : 1.0
    
    unique_xs = sort(unique(cartogram.x))
    step = length(unique_xs) > 1 ? minimum(diff(unique_xs)) : 1
    
    pop_lookup = Dict(
        r.h3 => (x = (r.x - lon_min)/lon_span, y = (r.y - lat_min)/lat_span) 
        for r in eachrow(population)
    )
    
    carto_norm = Dict{Tuple{Int, Int}, Tuple{Float64, Float64}}()
    for r in eachrow(cartogram)
        carto_norm[(r.x, r.y)] = ((r.x - cx_min)/cx_span, (r.y - cy_min)/cy_span)
    end
    
    grid = Dict{Tuple{Int, Int}, Int}()
    for (idx, r) in enumerate(eachrow(assignments))
        grid[(r.x, r.y)] = idx
    end
    
    dist(p1, p2) = sqrt((p1[1] - p2[1])^2 + (p1[2] - p2[2])^2)
    
    h3_arr = copy(assignments.h3)
    
    for pass in 1:passes
        swaps_made = 0
        for (coords, idx1) in grid
            cx1, cy1 = coords
            t1_norm = carto_norm[coords]
            h3_1 = h3_arr[idx1]
            p1_norm = pop_lookup[h3_1]
            
            # check adjacent neighbors: right and down
            for (dx, dy) in [(0, step), (step, 0)]
                neighbor_coords = (cx1 + dx, cy1 + dy)
                if haskey(grid, neighbor_coords)
                    idx2 = grid[neighbor_coords]
                    t2_norm = carto_norm[neighbor_coords]
                    h3_2 = h3_arr[idx2]
                    p2_norm = pop_lookup[h3_2]
                    
                    cost_curr = dist(t1_norm, (p1_norm.x, p1_norm.y)) + dist(t2_norm, (p2_norm.x, p2_norm.y))
                    cost_swap = dist(t1_norm, (p2_norm.x, p2_norm.y)) + dist(t2_norm, (p1_norm.x, p1_norm.y))
                    
                    if cost_swap < cost_curr
                        h3_arr[idx1], h3_arr[idx2] = h3_2, h3_1
                        h3_1 = h3_2
                        p1_norm = p2_norm
                        swaps_made += 1
                    end
                end
            end
        end
        println("Smoothing pass $pass: made $swaps_made geometric adjustments.")
        if swaps_made == 0
            break
        end
    end
    
    smoothed_assignments = copy(assignments)
    smoothed_assignments.h3 = h3_arr
    return smoothed_assignments
end

using JuMP, HiGHS, Base.Threads

"""
optimal transport with soft constraints
"""
function match_h3_to_cartogram_ot(
    population, 
    cartogram; 
    max_neighbors::Int=5, # the smaller this is the more it becomes like a geographic map, the bigger it is the more accurate it becomes, but it gets vastly slower
    penalty::Float64=100.0,
    silent::Bool=true
)
    pop_clean = filter(row -> row.population > 0.0, population)
    
    N = size(cartogram, 1)
    M = size(pop_clean, 1)
    
    if M == 0 || N == 0
        error("Input population or cartogram dataframe is empty.")
    end
    
    total_pop = sum(pop_clean.population)
    target_pop_per_cell = total_pop / N
    
    lat_min, lat_max = minimum(pop_clean.y), maximum(pop_clean.y)
    lon_min, lon_max = minimum(pop_clean.x), maximum(pop_clean.x)
    x_min, max_x = minimum(cartogram.x), maximum(cartogram.x)
    y_min, max_y = minimum(cartogram.y), maximum(cartogram.y)
    
    lon_span = (lon_max - lon_min) > 0 ? (lon_max - lon_min) : 1.0
    lat_span = (lat_max - lat_min) > 0 ? (lat_max - lat_min) : 1.0
    x_span = (max_x - x_min) > 0 ? (max_x - x_min) : 1.0
    y_span = (max_y - y_min) > 0 ? (max_y - y_min) : 1.0
    
    pop_norm_x = (pop_clean.x .- lon_min) ./ lon_span
    pop_norm_y = (pop_clean.y .- lat_min) ./ lat_span
    
    carto_norm_x = (cartogram.x .- x_min) ./ x_span
    carto_norm_y = (cartogram.y .- y_min) ./ y_span
    
    K = min(max_neighbors, N)
    total_pairs = M * K
    
    valid_pairs = Vector{Tuple{Int, Int}}(undef, total_pairs)
    distances = Vector{Float64}(undef, total_pairs)
    
    # probably worth turning this off because we'll want to multithread by country
    Threads.@threads for i in 1:M
        px, py = pop_norm_x[i], pop_norm_y[i]
        
        dists = Vector{Float64}(undef, N)
        for j in 1:N
            dists[j] = sqrt((px - carto_norm_x[j])^2 + (py - carto_norm_y[j])^2)
        end
        
        nearest_indices = partialsortperm(dists, 1:K)
        
        start_idx = (i - 1) * K + 1
        for (offset, j) in enumerate(nearest_indices)
            write_idx = start_idx + offset - 1
            valid_pairs[write_idx] = (i, j)
            distances[write_idx] = dists[j]
        end
    end
    
    model = Model(HiGHS.Optimizer)
    if silent
        set_silent(model)
    end
    
    set_attribute(model, "solver", "ipm")
    set_attribute(model, "threads", Threads.nthreads())
    
    @variable(model, w[1:total_pairs] >= 0)
    @variable(model, deficit[1:N] >= 0)
    @variable(model, surplus[1:N] >= 0)
    
    @objective(model, Min, 
        sum(w[idx] * distances[idx] for idx in 1:total_pairs) + 
        sum(penalty * (deficit[j] + surplus[j]) for j in 1:N)
    )
    
    # each H3 cell must distribute its exact population
    for i in 1:M
        start_idx = (i - 1) * K + 1
        @constraint(model, sum(w[idx] for idx in start_idx:(start_idx + K - 1)) == pop_clean.population[i])
    end
    
    # soft constraint: aim to fill each cell equally
    carto_to_indices = [Int[] for _ in 1:N]
    for idx in 1:total_pairs
        j = valid_pairs[idx][2]
        push!(carto_to_indices[j], idx)
    end
    
    for j in 1:N
        indices = carto_to_indices[j]
        @constraint(model, sum(w[idx] for idx in indices) + deficit[j] - surplus[j] == target_pop_per_cell)
    end
    
    optimize!(model)
    
    if termination_status(model) != OPTIMAL
        error("Solver failed to find a valid transport plan.")
    end
    
    assigned_h3 = Vector{Union{Nothing, UInt64}}()
    assigned_x = Vector{Int}()
    assigned_y = Vector{Int}()
    assigned_weight = Vector{Float64}()
    assigned_overlap = Vector{Float64}()
    
    sizehint!(assigned_h3, total_pairs)
    sizehint!(assigned_x, total_pairs)
    sizehint!(assigned_y, total_pairs)
    sizehint!(assigned_weight, total_pairs)
    sizehint!(assigned_overlap, total_pairs)
    
    w_vals = value.(w)
    
    for idx in 1:total_pairs
        overlap = w_vals[idx]
        if overlap > 1e-5
            i, j = valid_pairs[idx]
            h3_pop = pop_clean.population[i]
            weight = h3_pop > 0 ? (overlap / h3_pop) : 0.0
            
            push!(assigned_h3, pop_clean.h3[i])
            push!(assigned_x, cartogram.x[j])
            push!(assigned_y, cartogram.y[j])
            push!(assigned_weight, weight)
            push!(assigned_overlap, overlap)
        end
    end
    
    return DataFrame(
        h3 = assigned_h3, 
        x = assigned_x, 
        y = assigned_y, 
        weight = assigned_weight, 
        overlap = assigned_overlap
    )
end


H3_RES = 5
cities = CSV.read("population-data/tiny-cities.csv", DataFrame)
cities.h3 = H3.API.latLngToCell.(H3.API.LatLng.(deg2rad.(cities.latitude), deg2rad.(cities.longitude)), H3_RES)
_cities = cities[cities.country_code .== "FR", :][1:10, :]
_code = 249 # 826 UK, 250 France
ffs = Dict(249 => 250)
population.parent = ThreadsX.map(c -> H3.API.cellToParent(c, H3_RES), population.h3)
#subdivide_cartogram(cartogram[cartogram.code .== uk_code, :], 2) # somehow this alters the original data (!?)
cartogram = CSV.read("../data/cartogram.csv", DataFrame, header=false)
rename!(cartogram, [:x, :y, :code])
gc = groupby(cartogram, :code) # somehow doing this twice causes a segfault
# sanity check
# render_cartogram(gc[(826,)])
smaller_pop = combine(groupby(population, :parent), :population => sum => :population, :population => (p -> quantile(p, weights(collect(skipmissing(p))), 0.5)) => :median, :code => StatsBase.mode => :code)
rename!(smaller_pop, :parent => :h3)
smaller_pop.centre = ThreadsX.map(H3.API.cellToLatLng, smaller_pop.h3)
smaller_pop.x = rad2deg.(map(x -> x.lng, smaller_pop.centre))
smaller_pop.y = rad2deg.(map(x -> -x.lat, smaller_pop.centre))
sort!(smaller_pop, [:x, :y])
gp = groupby(smaller_pop, :code)

all_countries = intersect(unique(cartogram.code), unique(smaller_pop.code))
#df = reduce(vcat,ThreadsX.map(c -> begin
    c = _code
    c_ffs = get(ffs, c, c)
    # ffs brilliant the codes don't match perfectly. for them france is 250, for us it is 249. so we're buggered unless we find the data they were using
    # or go back and make this all ourself
    _mini_cartogram = copy(DataFrame(gc[(c_ffs,)]))
    mini_cartogram = subdivide_cartogram(_mini_cartogram, 1)
    mini_population = gp[(c,)]
    # mini_df = match_h3_to_cartogram_stripey(mini_population, mini_cartogram)
    mini_df = match_h3_to_cartogram_ot(mini_population, mini_cartogram, max_neighbors=100)
    df = mini_df
#    @info c
#    mini_df
#end, [_code]))


toplot = leftjoin(df, smaller_pop[:, Not([:x, :y])], on=:h3)
toplot = leftjoin(toplot, _cities[:, [:h3, :name]], on=:h3)
almost_there = combine(groupby(toplot, [:x, :y]), [:median, :weight] => ((m,w) -> quantile(m, weights(collect(skipmissing(w))), 0.5)) => :median, :name => (n -> join(collect(skipmissing(n)), ", ")) => :label, [:population, :weight] => ((p, w) -> sum(p.*w)) => :population)
almost_there.label = map(x -> x == "" ? missing : x, almost_there.label)
addquantiles!(almost_there, :median)
addquantiles!(almost_there, :population)
almost_there.population_z = (almost_there.population ./ mean(almost_there.population)) ./ 2

# this is just for sense checking: it should all be the same colour
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:population_z, draw_outline=false, square_size=100, font_size=50, filename="population_check.png")

# this is the actual map
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_quantile, draw_outline=false, square_size=100, font_size=50)

# reducing the resolution makes it tractable
# could we subsample using hilbert?


# ok i think this is promising really
# todo:
# 1) sort out the missing country codes (our 249 for france, their 250), see https://en.wikipedia.org/wiki/ISO_3166-1_numeric
# 2) do a first pass on the planet using a low number of neighbours seeing if stuff looks kind reasonable
# 3) increase neighbours?
# 4) think about subsampling?
# 5) try to work out how to draw borders?
