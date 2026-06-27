#!/bin/julia
using CSV, DataFrames, Luxor, Arrow, ThreadsX, StatsBase, ColorSchemes, ProgressMeter, Printf
import H3
import Colors: RGB

countries = CSV.read("../data/country-code.csv", DataFrame)

function _comma_group_number(raw::AbstractString)
    sign = startswith(raw, "-") ? "-" : ""
    unsigned = isempty(sign) ? raw : raw[2:end]
    parts = String[]
    while length(unsigned) > 3
        pushfirst!(parts, unsigned[end-2:end])
        unsigned = unsigned[1:end-3]
    end
    pushfirst!(parts, unsigned)
    return sign * join(parts, ",")
end

function _format_legend_number(x::Real; sigdigits::Int=2)
    if !isfinite(x)
        return string(x)
    end

    rounded = round(Float64(x); sigdigits=sigdigits)
    if rounded == 0
        return "0"
    end

    decimal_places = max(0, sigdigits - floor(Int, log10(abs(rounded))) - 1)
    raw = @sprintf("%.*f", decimal_places, rounded)
    pieces = split(raw, "."; limit=2)
    whole = _comma_group_number(pieces[1])
    return length(pieces) == 1 ? whole : whole * "." * pieces[2]
end

_format_legend_label(x) = x isa Real ? _format_legend_number(x) : string(x)

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
    coord_step::Real=2,
    draw_legend::Bool=false,
    legend_label_field::Union{Nothing, Symbol}=nothing,
    legend_title::Union{Nothing, String}=nothing,
    legend_ticks=0:0.25:1,
    legend_label_formatter = _format_legend_label,
    legend_bar_width::Real=max(12, 3 * square_size),
    legend_bar_height::Real=max(80, 3 * 6 * square_size),
    legend_font_size::Real=font_size
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
    
    if draw_legend
        legend_label_values = nothing
        if !isnothing(legend_label_field)
            if !(string(legend_label_field) in names(cartogram))
                error("legend_label_field $(legend_label_field) is not a column in cartogram")
            end
            legend_label_values = collect(skipmissing(cartogram[!, legend_label_field]))
            if isempty(legend_label_values)
                error("legend_label_field $(legend_label_field) has no non-missing values")
            end
        end
        
        ticks = collect(legend_ticks)
        if isempty(ticks)
            ticks = [0, 0.25, 0.5, 0.75, 1]
        end
        
        legend_margin = max(6, padding / 4)
        legend_left = -width / 2 + legend_margin
        legend_top = -height / 2 + legend_margin
        box_padding = max(4, legend_font_size * 0.5)
        tick_length = max(4, legend_bar_width * 0.35)
        label_gap = max(4, legend_font_size * 0.4)
        label_width = max(70, legend_font_size * 7)
        title_height = isnothing(legend_title) ? 0 : legend_font_size * 1.4
        tick_label_padding = legend_font_size * 0.6
        backing_width = legend_bar_width + tick_length + label_gap + label_width + 2 * box_padding
        backing_height = title_height + legend_bar_height + 2 * tick_label_padding + 2 * box_padding
        
        sethue("white")
        box(
            Point(legend_left + backing_width / 2, legend_top + backing_height / 2),
            backing_width,
            backing_height,
            :fill
        )
        sethue("black")
        setline(0.5)
        box(
            Point(legend_left + backing_width / 2, legend_top + backing_height / 2),
            backing_width,
            backing_height,
            :stroke
        )
        
        fontface(font_face)
        fontsize(legend_font_size)
        content_x = legend_left + box_padding
        content_y = legend_top + box_padding
        if !isnothing(legend_title)
            sethue(text_color)
            text(legend_title, Point(content_x, content_y + legend_font_size / 2), halign=:left, valign=:middle)
            content_y += title_height
        end
        bar_top = content_y + tick_label_padding
        
        steps = 64
        step_height = legend_bar_height / steps
        for i in 1:steps
            q = 1 - (i - 0.5) / steps
            sethue(legend(q))
            box(
                Point(content_x + legend_bar_width / 2, bar_top + (i - 0.5) * step_height),
                legend_bar_width,
                step_height + 0.5,
                :fill
            )
        end
        
        sethue(text_color)
        setline(0.5)
        box(
            Point(content_x + legend_bar_width / 2, bar_top + legend_bar_height / 2),
            legend_bar_width,
            legend_bar_height,
            :stroke
        )
        
        for q in ticks
            qv = clamp(Float64(q), 0.0, 1.0)
            tick_y = bar_top + (1 - qv) * legend_bar_height
            line(
                Point(content_x + legend_bar_width, tick_y),
                Point(content_x + legend_bar_width + tick_length, tick_y),
                :stroke
            )
            label_value = isnothing(legend_label_values) ? qv : quantile(legend_label_values, qv)
            text(
                legend_label_formatter(label_value),
                Point(content_x + legend_bar_width + tick_length + label_gap, tick_y),
                halign=:left,
                valign=:middle
            )
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
