#!/bin/julia
using CSV, DataFrames, Luxor

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
        
        sethue(legend(row[field])...)
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
