#!/bin/julia
using CSV, DataFrames, Luxor, Arrow, ThreadsX, StatsBase, ColorSchemes
import H3

cartogram = CSV.read("../data/cartogram.csv", DataFrame, header=false)
rename!(cartogram, [:x, :y, :code])
countries = CSV.read("../data/country-code.csv", DataFrame)
country_colours = Dict(c => rand(3) for c in unique(cartogram.code))

function render_cartogram(
    cartogram::DataFrame; 
    legend = z -> get(country_colours, z, 0), # lookup function data -> colour
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
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_quantile, draw_outline=false, square_size=10, font_size=40)

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

european_countries = ["Albania", "Andorra", "Austria", "Belgium", "Bosnia and Herzegovina", "Bulgaria", "Belarus", "Cyprus", "Croatia", "Czechia", "Denmark", "Estonia", "Faeroe Islands", "Finland", "<span data-sort-value=\"Aland Islands !\">Åland Islands", "France", "Germany", "Gibraltar", "Greece", "Hungary", "Iceland", "Ireland", "Italy", "Latvia", "Liechtenstein", "Lithuania", "Luxembourg", "Malta", "Monaco", "Moldova", "Montenegro", "Netherlands", "Norway", "Poland", "Portugal", "Romania", "San Marino", "Serbia", "Slovakia", "Slovenia", "Spain", "Svalbard and Jan Mayen", "Sweden", "Switzerland", "Ukraine", "North Macedonia", "United Kingdom", "Guernsey", "Jersey", "Isle of Man", "Vatican"]
europe = semijoin(cartogram, countries[in.(countries.name, Ref(european_countries)), :], on=:code)
render_cartogram(europe)

# ok fun drawing time over. let's do some lookup tables

population = copy(Arrow.Table("population-data/kontur_population_20231101.arrow") |> DataFrame)
population.centre = ThreadsX.map(H3.API.cellToLatLng, population.h3)

# for cartogram,
# y increases as latitude decreases
# x increases as longitude increases
# =>
population.x = map(x -> x.lng, population.centre)
population.y = map(x -> -x.lat, population.centre)

sort!(cartogram, [:x, :y])
sort!(population, [:x, :y])

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

function match_h3_to_cartogram(population::DataFrame, cartogram::DataFrame)
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

H3_RES = 6
population.parent = ThreadsX.map(c -> H3.API.cellToParent(c, H3_RES), population.h3)
mini_pop = combine(groupby(population, :parent), :population => sum => :population, :population => (p -> quantile(p, weights(collect(skipmissing(p))), 0.5)) => :median)
rename!(mini_pop, :parent => :h3)
mini_pop.centre = ThreadsX.map(H3.API.cellToLatLng, mini_pop.h3)
mini_pop.x = rad2deg.(map(x -> x.lng, mini_pop.centre))
mini_pop.y = rad2deg.(map(x -> -x.lat, mini_pop.centre))
sort!(mini_pop, [:x, :y])

#pls = match_h3_to_cartogram(mini_pop, cartogram)

bigger = subdivide_cartogram(cartogram, 1)
raw_assignments = match_h3_to_cartogram(mini_pop, bigger)
pls = relax_assignments_2d(raw_assignments, mini_pop, bigger, passes=2)

cities = CSV.read("population-data/tiny-cities.csv", DataFrame)
cities.h3 = H3.API.latLngToCell.(H3.API.LatLng.(cities.latitude, cities.longitude), H3_RES)

toplot = leftjoin(pls, mini_pop[:, Not([:x, :y])], on=:h3)
leftjoin!(toplot, cities[:, [:h3, :name]], on=:h3)
almost_there = combine(groupby(toplot, [:x, :y]), [:median, :weight] => ((m,w) -> quantile(m, weights(collect(skipmissing(w))), 0.5)) => :median, :name => (n -> join(collect(skipmissing(n)), ", ")) => :label)
almost_there.label = map(x -> x == "" ? missing : x, almost_there.label) # i don't understand why there are only 9
addquantiles!(almost_there, :median)
almost_there.median_z = (almost_there.median .- mean(almost_there.median)) ./  std(almost_there.median) .+ 1.0

render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_quantile, draw_outline=false, square_size=10, font_size=40)
