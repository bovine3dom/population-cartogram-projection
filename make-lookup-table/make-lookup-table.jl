#!/bin/julia
using CSV, DataFrames, Luxor, Arrow, ThreadsX, StatsBase
import H3

# end 200 200 "hello.png"; # dunno how to make width/heigh optional?

cartogram = CSV.read("../data/cartogram.csv", DataFrame, header=false)
rename!(cartogram, [:x, :y, :code])
countries = CSV.read("../data/country-code.csv", DataFrame)
country_colours = Dict(c => rand(3) for c in unique(cartogram.code))

function render_cartogram(
    cartogram::DataFrame, 
    legend = z -> get(country_colours, z, 0), # lookup function data -> colour
    field::Symbol = :code,
    square_size::Real=10,
    draw_outline::Bool=true,
    outline_color::String="black",
    outline_width::Real=0.5,
    padding::Real=20,
    filename::String="hello.png"
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

function match_h3_to_cartogram(population, cartogram)
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

population.parent = ThreadsX.map(c -> H3.API.cellToParent(c, 4), population.h3)

mini_pop = combine(groupby(population, :parent), :population => sum => :population, :population => (p -> quantile(p, weights(collect(skipmissing(p))), 0.5)) => :median)
rename!(mini_pop, :parent => :h3)

pls = match_h3_to_cartogram(mini_pop, cartogram)
toplot = leftjoin(pls, mini_pop, on=:h3)
almost_there = combine(groupby(toplot, [:x, :y]), [:median, :weight] => ((m,w) -> quantile(m, weights(collect(skipmissing(w))), 0.5)) => :median)

using ColorSchemes

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
addquantiles!(almost_there, :median)

render_cartogram(almost_there, z -> get(ColorSchemes.Spectral, z), :median_quantile)

# cool so main takeaway: this is way too stripey so we need to use the hungarian thing
