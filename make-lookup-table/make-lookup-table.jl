#!/bin/julia
using CSV, DataFrames, Luxor, Arrow, ThreadsX, StatsBase, ColorSchemes, ProgressMeter
import H3
import Colors: RGB

include("lib.jl")
include("cuRegOT.jl")

cartogram = Arrow.Table("cartogram.arrow") |> DataFrame # pls fix the corruption? pls?
country_colours = Dict(c => rand(3) for c in unique(cartogram.code))
render_cartogram(cartogram)
H3_RES = 5
cities = CSV.read("population-data/tiny-cities.csv", DataFrame)
cities.h3 = H3.API.latLngToCell.(H3.API.LatLng.(deg2rad.(cities.latitude), deg2rad.(cities.longitude)), H3_RES)
# max top 3 cities per country
# _cities = cities[cities.country_code .== "FR", :][1:10, :]
# _code = 249 # 826 UK, 250 France
population.parent = ThreadsX.map(c -> H3.API.cellToParent(c, H3_RES), population.h3)
#subdivide_cartogram(cartogram[cartogram.code .== uk_code, :], 2) # somehow this alters the original data (!?)
# sanity check
# render_cartogram(gc[(826,)])
smaller_pop = combine(groupby(population, :parent), :population => sum => :population, :population => (p -> quantile(p, weights(collect(skipmissing(p))), 0.5)) => :median, :code => StatsBase.mode => :code)
rename!(smaller_pop, :parent => :h3)
smaller_pop.centre = ThreadsX.map(H3.API.cellToLatLng, smaller_pop.h3)
smaller_pop.x = rad2deg.(map(x -> x.lng, smaller_pop.centre))
smaller_pop.y = rad2deg.(map(x -> -x.lat, smaller_pop.centre))
sort!(smaller_pop, [:x, :y])
gp = groupby(smaller_pop, :code)

# sidequest: build matching between codes from OWID and Natural Earth
ne_countries = unique(smaller_pop.code)
ne_only = setdiff(ne_countries, countries.code) # -99 (sea), 249, (france)
rename!(cartogram, [:x, :y, :code])
gc = groupby(cartogram, :code) # somehow doing this twice causes a segfault
owid_only = setdiff(unique(cartogram.code), ne_countries) # 28 (antigua), 250 (france), 492 (monaco)
ffs = Dict(250 => 249) # ok so we need to map france 249 => 250 and skip 28, 336, 581
all_countries = setdiff(intersect(cartogram.code, europe_codes), setdiff(owid_only, keys(ffs))) # seems to miss approx 50 countries? presumably microstates?
results = []
# somehow something in here MUTATES the cartogram(!!!!)
length(unique(cartogram.code))
# let's check china works with 100 neighbours first - big population, big area, unevenly distributed
@showprogress Threads.@threads for _code in all_countries
    try
        owid_code = _code
        ne_code = get(ffs, owid_code, owid_code)
        mini_cartogram = deepcopy(gc[(owid_code,)])
        mini_population = gp[(ne_code,)]
        # mini_df = match_h3_to_cartogram_stripey(mini_population, mini_cartogram)
        mini_df = match_h3_to_cartogram_ot(mini_population, mini_cartogram, max_neighbors=100, penalty=200.0)
        # i am thinking our best bet is really just to use optimal transport and mask out the parts of the map where the population is too small
        # sidequest - integer downsample large countries then upsample back to exact original grid
        push!(results, mini_df)
    catch (e)
        @warn e
    end
end
length(unique(cartogram.code))
results
df = reduce(vcat, results)
#    @info c
#    mini_df
#end, [_code]))

toplot = leftjoin(df, smaller_pop[:, Not([:x, :y])], on=:h3)
toplot = leftjoin(toplot, _cities[:, [:h3, :name]], on=:h3)
# sort!(toplot, :weight)
# toplot.name = collect(Iterators.map(p -> p[1] ? p[2] : missing, zip(.!nonunique(toplot, :name), toplot.name))) # ideally this would be a weighted average
assign_weighted_labels!(toplot, label_col=:name, weight_col=:weight, target_col=:label)

# TODO:
# h3 needs to be stringified
# need to add weight_mean column that is weight*(h3 cell population) / (total cartogram cell population)

# write the data out for reuse
# dropmissing!(toplot, Not([:name, :label]))
# Arrow.write("mapping.arrow", toplot[!, [:h3, :x, :y, :weight, :population, :code, :label]]) # the thing we actually want. H3 res = 5
# dropmissing!(smaller_pop, :h3)
# Arrow.write("out.arrow", smaller_pop[!, [:h3, :median]]) # so now the challenge is: group by and plot on client side
# df = copy(Arrow.Table("mapping.arrow") |> DataFrame)

almost_there = combine(groupby(toplot, [:x, :y]), [:median, :weight] => ((m,w) -> quantile(m, weights(collect(skipmissing(w))), 0.5)) => :median, :label => (n -> join(collect(skipmissing(n)), ", ")) => :label, [:population, :weight] => ((p, w) -> sum(p.*w)) => :population, :code => StatsBase.mode => :code)
almost_there.label = map(x -> x == "" ? missing : x, almost_there.label)
addquantiles!(almost_there, :median)
addquantiles!(almost_there, :population)
almost_there.population_z = (almost_there.population ./ mean(almost_there.population)) ./ 2
almost_there.median_z = (almost_there.median .- mean(almost_there.median)) ./ (2 * std(almost_there.median)) .+ 0.5

# this is just for sense checking: it should all be the same colour
RENDER_SCALE = 20
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:population_z, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, filename="population_check.png", draw_country_borders=true, padding=RENDER_SCALE*10)

# this is the actual map
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_quantile, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, draw_country_borders=true, padding=RENDER_SCALE*10)
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_z, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, draw_country_borders=true, padding=RENDER_SCALE*10)

# reducing the resolution makes it tractable
# could we subsample using hilbert?


# ok i think this is promising really
# todo:
# 1) increase neighbours?
# 2) think about subsampling?
# 3) document reuse, move plotting code to library
# 4) attempt first reuse. e.g. vacant properties in france?

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

# bof. it looks kind of fine in the centre but at the borders it is mega dodge
# fixed with the f32 -> f0 bug. but now it's slow? is it really no faster than the jump solver?
_code = countries[countries.name .== "India", :code][1] # 826 uk # 356 india # 156 china
owid_code = _code
ne_code = get(ffs, owid_code, owid_code)
# gc = groupby(cartogram, :code) # somehow doing this twice causes a segfault
owid_only = setdiff(unique(cartogram.code), ne_countries) # 28 (antigua), 250 (france), 492 (monaco)
# somehow something in here MUTATES the cartogram(!!!!) # switching from csv to arrow fixed it.
mini_cartogram = subdivide_cartogram(cartogram[cartogram.code .== owid_code, :], 1) # do not do this for big countries. lol.
render_cartogram(mini_cartogram)
mini_population = gp[(ne_code,)]
# mini_df = match_h3_to_cartogram_stripey(mini_population, mini_cartogram)
# mini_df = match_h3_to_cartogram_curegot(DataFrame(mini_population), DataFrame(mini_cartogram); eta = 0.001f0, max_iters=100, k=2_000)#, threshold=1e36)
mini_df = match_h3_to_cartogram_stable(DataFrame(mini_population), DataFrame(mini_cartogram); eta = 0.0001f0, max_iters=100_000, tol=0.05)#, threshold=1e36)
# still too stripey for india
# mini_df = match_h3_to_cartogram_ot(mini_population, mini_cartogram, max_neighbors=100, penalty=400.0)
# for reference: soft ot only yields 1,600 matches, compared to ~26,000 with sinkhorn
# i am thinking our best bet is really just to use optimal transport and mask out the parts of the map where the population is too small
# sidequest - integer downsample large countries then upsample back to exact original grid
#
_cities = combine(groupby(cities, :country_code), g -> g[1:min(10, nrow(g)), :])
_cities = _cities[_cities.population .> 100_000, :]
toplot = leftjoin(mini_df, smaller_pop[:, Not([:x, :y])], on=:h3)
toplot = leftjoin(toplot, _cities[:, [:h3, :name]], on=:h3)
# sort!(toplot, :weight)
# toplot.name = collect(Iterators.map(p -> p[1] ? p[2] : missing, zip(.!nonunique(toplot, :name), toplot.name))) # ideally this would be a weighted average
assign_weighted_labels!(toplot, label_col=:name, weight_col=:weight, target_col=:label)

almost_there = combine(groupby(toplot, [:x, :y]), [:median, :weight] => ((m,w) -> quantile(m, weights(collect(skipmissing(w))), 0.5)) => :median, :label => (n -> join(collect(skipmissing(n)), ", ")) => :label, [:population, :weight] => ((p, w) -> sum(p.*w)) => :population, :code => StatsBase.mode => :code, nrow)
almost_there.label = map(x -> x == "" ? missing : x, almost_there.label)
addquantiles!(almost_there, :median)
addquantiles!(almost_there, :population)
almost_there.population_z = (almost_there.population ./ mean(almost_there.population)) ./ 2
almost_there.median_z = (almost_there.median .- mean(almost_there.median)) ./ (2 * std(almost_there.median)) .+ 0.5
almost_there.nrow_z = (almost_there.nrow ./ maximum(almost_there.nrow))

# this is just for sense checking: it should all be the same colour
RENDER_SCALE = 20
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:population_z, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, filename="population_check.png", draw_country_borders=true, padding=RENDER_SCALE*10)

# this is the actual map
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_quantile, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, draw_country_borders=true, padding=RENDER_SCALE*10)
# render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_z, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, draw_country_borders=true, padding=RENDER_SCALE*10)

# todo:
# it's still too smeared
# but i can't reduce eta more without getting errors
#
# increasing the threshold doesn't help much because stuff is still extremely smeared
# for reference: for the uk jump/highs soft ot only yields 1,600 matches, compared to ~50,000 with sinkhorn
