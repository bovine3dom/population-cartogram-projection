#!/bin/julia
using CSV, DataFrames, Luxor, Arrow, ThreadsX, StatsBase, ColorSchemes, ProgressMeter
import H3
import Colors: RGB

countries = CSV.read("../data/country-code.csv", DataFrame)

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
    text_color::String="black",
    draw_country_borders::Bool=false,
    country_border_color::String="black",
    country_border_width::Real=1.5,
    include_outer_borders::Bool=false,
    coord_step::Real=2
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
    
    if draw_country_borders
        cell_map = Dict((row.x, row.y) => row[:code] for row in eachrow(cartogram))
        sethue(country_border_color)
        setline(country_border_width)
        for row in eachrow(cartogram)
            cx = (row.x - center_x) * square_size/2
            cy = (row.y - center_y) * square_size/2
            x, y = row.x, row.y
            code = row[:code]
            r_neighbor = (x + coord_step, y)
            r_code = get(cell_map, r_neighbor, nothing)
            if !isequal(r_code, code) && (include_outer_borders || !isnothing(r_code))
                line(
                    Point(cx + square_size/2, cy - square_size/2),
                    Point(cx + square_size/2, cy + square_size/2),
                    :stroke
                )
            end
            b_neighbor = (x, y + coord_step)
            b_code = get(cell_map, b_neighbor, nothing)
            if !isequal(b_code, code) && (include_outer_borders || !isnothing(b_code))
                line(
                    Point(cx - square_size/2, cy + square_size/2),
                    Point(cx + square_size/2, cy + square_size/2),
                    :stroke
                )
            end
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
add a label column for the cell closest to the weighted average of x,y for each label
"""
function assign_weighted_labels!(
    df::DataFrame; 
    label_col::Symbol=:name, 
    weight_col::Symbol=:weight, 
    target_col::Symbol=:label
)
    LabelType = Union{Missing, nonmissingtype(eltype(df[!, label_col]))}
    df[!, target_col] = Vector{LabelType}(missing, nrow(df))
    
    df.temp_idx = 1:nrow(df)
    df_labeled = filter(row -> !ismissing(row[label_col]) && !isnothing(row[label_col]), df)
    gdf = groupby(df_labeled, label_col)
    
    for sub_df in gdf
        label_val = first(sub_df[!, label_col])
        sum_w = sum(sub_df[!, weight_col])
        if sum_w > 0
            mean_x = sum(sub_df.x .* sub_df[!, weight_col]) / sum_w
            mean_y = sum(sub_df.y .* sub_df[!, weight_col]) / sum_w
        else
            mean_x = mean(sub_df.x)
            mean_y = mean(sub_df.y)
        end
        distances = (sub_df.x .- mean_x).^2 .+ (sub_df.y .- mean_y).^2
        best_sub_idx = argmin(distances)
        orig_row_idx = sub_df[best_sub_idx, :temp_idx]
        df[orig_row_idx, target_col] = label_val
    end
    select!(df, Not(:temp_idx))
    return df
end
