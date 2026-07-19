#!/usr/bin/env julia

module FranceDensityRenderer

using CSV
using ColorSchemes
using Colors: RGB
using DataFrames
using Luxor
using Printf
using StatsBase: ecdf, quantile

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_OUTPUT_DIR = joinpath(ROOT, "output", "france-iris-factor3")
const DEFAULT_INPUT = joinpath(DEFAULT_OUTPUT_DIR, "projected_population_density.csv")
const CELL_SIZE = 10.0
const MAP_PADDING = 64.0
const TITLE_HEIGHT = 100.0
const FOOTER_HEIGHT = 44.0
const LEGEND_WIDTH = 230.0

function comma_number(value::Real)
    raw = string(round(Int, value))
    parts = String[]
    while length(raw) > 3
        pushfirst!(parts, raw[end-2:end])
        raw = raw[1:end-3]
    end
    pushfirst!(parts, raw)
    return join(parts, ',')
end

function density_label(value::Real)
    value >= 100 ? comma_number(value) :
    value >= 10 ? @sprintf("%.1f", value) :
    @sprintf("%.2f", value)
end

function render_map(frame, output_path; subtitle, color_position, legend_ticks)
    xs = Float64.(frame.grid_x)
    ys = Float64.(frame.grid_y)
    min_x, max_x = extrema(xs)
    min_y, max_y = extrema(ys)
    step_x = minimum(diff(sort(unique(xs))))
    step_y = minimum(diff(sort(unique(ys))))
    map_width = (max_x - min_x) / step_x * CELL_SIZE + CELL_SIZE + 2MAP_PADDING
    map_height = (max_y - min_y) / step_y * CELL_SIZE + CELL_SIZE + 2MAP_PADDING
    width = ceil(Int, map_width + LEGEND_WIDTH)
    height = ceil(Int, TITLE_HEIGHT + map_height + FOOTER_HEIGHT)
    left = -width / 2
    top = -height / 2
    map_center = Point(left + map_width / 2, top + TITLE_HEIGHT + map_height / 2)
    center_x = (min_x + max_x) / 2
    center_y = (min_y + max_y) / 2
    point_for(x, y) = Point(
        map_center.x + (x - center_x) * CELL_SIZE / step_x,
        map_center.y + (y - center_y) * CELL_SIZE / step_y,
    )
    color_for(value) = ismissing(value) || !isfinite(value) ? RGB(0.82, 0.82, 0.82) :
                       get(ColorSchemes.inferno, clamp(color_position(Float64(value)), 0, 1))

    Drawing(width, height, output_path)
    origin()
    background("#f7f4ee")

    fontface("DejaVu Sans Bold")
    fontsize(28)
    sethue("#171717")
    text("France population density", Point(left + 34, top + 38); halign=:left, valign=:middle)
    fontface("DejaVu Sans")
    fontsize(14)
    sethue("#4a4a4a")
    text(subtitle, Point(left + 34, top + 70); halign=:left, valign=:middle)

    for row in eachrow(frame)
        center = point_for(row.grid_x, row.grid_y)
        sethue(color_for(row.population_density))
        box(center, CELL_SIZE, CELL_SIZE, :fill)
    end

    occupied = Set(zip(frame.grid_x, frame.grid_y))
    sethue("#252525")
    setline(1.2)
    half = CELL_SIZE / 2
    for row in eachrow(frame)
        center = point_for(row.grid_x, row.grid_y)
        (row.grid_x - step_x, row.grid_y) in occupied ||
            line(Point(center.x - half, center.y - half), Point(center.x - half, center.y + half), :stroke)
        (row.grid_x + step_x, row.grid_y) in occupied ||
            line(Point(center.x + half, center.y - half), Point(center.x + half, center.y + half), :stroke)
        (row.grid_x, row.grid_y - step_y) in occupied ||
            line(Point(center.x - half, center.y - half), Point(center.x + half, center.y - half), :stroke)
        (row.grid_x, row.grid_y + step_y) in occupied ||
            line(Point(center.x - half, center.y + half), Point(center.x + half, center.y + half), :stroke)
    end

    fontface("DejaVu Sans Bold")
    fontsize(14)
    for row in eachrow(frame)
        ismissing(row.label) && continue
        center = point_for(row.grid_x, row.grid_y)
        direction = row.label == "Marne La Vallée" ? 1 : center.x > map_center.x ? -1 : 1
        alignment = direction > 0 ? :left : :right
        text_point = Point(center.x + 8direction, center.y)
        sethue("white")
        setline(4)
        textoutlines(row.label, text_point, :stroke; halign=alignment, valign=:middle)
        sethue("#111111")
        text(row.label, text_point; halign=alignment, valign=:middle)
        sethue("white")
        circle(center, 3.2, :fill)
        sethue("#111111")
        setline(1)
        circle(center, 3.2, :stroke)
    end

    legend_left = left + map_width + 46
    legend_top = top + TITLE_HEIGHT + 150
    legend_height = 360.0
    legend_width = 28.0
    fontface("DejaVu Sans Bold")
    fontsize(15)
    sethue("#171717")
    text("people / km²", Point(legend_left, legend_top - 28); halign=:left, valign=:middle)
    steps = 128
    for index in 1:steps
        position = (index - 0.5) / steps
        y = legend_top + (1 - position) * legend_height
        sethue(get(ColorSchemes.inferno, position))
        box(Point(legend_left + legend_width / 2, y), legend_width, legend_height / steps + 0.5, :fill)
    end
    sethue("#252525")
    setline(0.8)
    box(
        Point(legend_left + legend_width / 2, legend_top + legend_height / 2),
        legend_width,
        legend_height,
        :stroke,
    )
    fontface("DejaVu Sans")
    fontsize(13)
    for (position, value) in legend_ticks
        y = legend_top + (1 - position) * legend_height
        line(Point(legend_left + legend_width, y), Point(legend_left + legend_width + 7, y), :stroke)
        text(
            density_label(value),
            Point(legend_left + legend_width + 12, y);
            halign=:left,
            valign=:middle,
        )
    end

    fontface("DejaVu Sans")
    fontsize(11)
    sethue("#5a5a5a")
    text(
        "INSEE 2022 IRIS population / ellipsoidal area · GeoNames cities >300k",
        Point(left + 34, height / 2 - 19);
        halign=:left,
        valign=:middle,
    )
    finish()
    return (; width, height)
end

function main(args=ARGS)
    length(args) <= 2 || error("usage: render_density.jl [INPUT_CSV] [OUTPUT_DIRECTORY]")
    input_path = isempty(args) ? DEFAULT_INPUT : abspath(args[1])
    output_dir = length(args) < 2 ? dirname(input_path) : abspath(args[2])
    isfile(input_path) || error("projected density CSV not found: $input_path")
    mkpath(output_dir)

    frame = CSV.read(input_path, DataFrame)
    required = [:cell_id, :grid_x, :grid_y, :population_density, :label]
    all(column -> column in propertynames(frame), required) ||
        error("projected density CSV is missing required columns")
    values = Float64.(collect(skipmissing(frame.population_density)))
    all(isfinite, values) || error("population density must be finite")
    length(values) == nrow(frame) || error("population density is missing for some cells")
    subdivision_factors = Int[]
    for cell in frame.cell_id
        matched = match(r":sub(\d+):", string(cell))
        isnothing(matched) || push!(subdivision_factors, parse(Int, matched[1]))
    end
    unique!(subdivision_factors)
    length(subdivision_factors) <= 1 || error("cell ids contain mixed subdivision factors")
    factor = isempty(subdivision_factors) ? 1 : only(subdivision_factors)
    cartogram_label = "Factor $factor cartogram"

    distribution = ecdf(values)
    minimum_rank = minimum(distribution.(values))
    quantile_position(value) = (distribution(value) - minimum_rank) / (1 - minimum_rank)
    quantile_ticks = [(q, quantile(values, q)) for q in 0:0.25:1]

    log_min = quantile(values, 0.01)
    log_max = quantile(values, 0.99)
    log_position(value) = (log10(max(value, log_min)) - log10(log_min)) /
                          (log10(log_max) - log10(log_min))
    log_ticks = [
        (q, 10.0^(log10(log_min) + q * (log10(log_max) - log10(log_min))))
        for q in 0:0.25:1
    ]

    linear_max = quantile(values, 0.99)
    linear_position(value) = value / linear_max
    linear_ticks = [(q, q * linear_max) for q in 0:0.25:1]

    outputs = [
        (
            "france_population_density_quantile.png",
            "$cartogram_label · population-weighted IRIS density · empirical quantile scale",
            quantile_position,
            quantile_ticks,
        ),
        (
            "france_population_density_log.png",
            "$cartogram_label · population-weighted IRIS density · log scale (1st–99th percentile)",
            log_position,
            log_ticks,
        ),
        (
            "france_population_density_linear_p99.png",
            "$cartogram_label · population-weighted IRIS density · linear scale clipped at p99",
            linear_position,
            linear_ticks,
        ),
    ]
    paths = String[]
    for (filename, subtitle, color_position, legend_ticks) in outputs
        path = joinpath(output_dir, filename)
        dimensions = render_map(
            frame,
            path;
            subtitle,
            color_position,
            legend_ticks,
        )
        println("Wrote $path ($(dimensions.width)x$(dimensions.height))")
        push!(paths, path)
    end
    return paths
end

end


if abspath(PROGRAM_FILE) == @__FILE__
    FranceDensityRenderer.main(ARGS)
end
