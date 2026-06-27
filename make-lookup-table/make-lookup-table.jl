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
function city_labels_by_h3(cities::DataFrame; min_population::Real=300_000)
    selected = cities[cities.population .> min_population, [:h3, :name, :population]]
    sort!(selected, [:h3, :population], rev=[false, true])
    return combine(groupby(selected, :h3), :name => (n -> join(unique(collect(skipmissing(n))), ", ")) => :name)
end
_cities = city_labels_by_h3(cities)
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
european_countries = ["Albania", "Andorra", "Austria", "Belgium", "Bosnia and Herzegovina", "Bulgaria", "Belarus", "Cyprus", "Croatia", "Czechia", "Denmark", "Estonia", "Faeroe Islands", "Finland", "<span data-sort-value=\"Aland Islands !\">Åland Islands", "France", "Germany", "Gibraltar", "Greece", "Hungary", "Iceland", "Ireland", "Italy", "Latvia", "Liechtenstein", "Lithuania", "Luxembourg", "Malta", "Monaco", "Moldova", "Montenegro", "Netherlands", "Norway", "Poland", "Portugal", "Romania", "San Marino", "Serbia", "Slovakia", "Slovenia", "Spain", "Svalbard and Jan Mayen", "Sweden", "Switzerland", "Ukraine", "North Macedonia", "United Kingdom", "Guernsey", "Jersey", "Isle of Man", "Vatican"]
# europe = semijoin(cartogram, countries[in.(countries.name, Ref(european_countries)), :], on=:code)
europe_codes = countries[in.(countries.name, Ref(european_countries)), :code]
# all_countries = setdiff(intersect(cartogram.code, europe_codes), setdiff(owid_only, keys(ffs))) # seems to miss approx 50 countries? presumably microstates?
all_countries = setdiff(cartogram.code, setdiff(owid_only, keys(ffs))) # seems to miss approx 50 countries? presumably microstates?
results = []
# somehow something in here MUTATES the cartogram(!!!!)
length(unique(cartogram.code))
# let's check china works with 100 neighbours first - big population, big area, unevenly distributed
countries_to_process = all_countries
sinkhorn_candidate_final_etas = Float32[0.005, 0.002, 0.001, 0.0005, 0.0002, 0.0001, 0.00005]
sinkhorn_max_iters_per_eta = 5000
sinkhorn_cost_power = 2.0
sinkhorn_target_rows_multiplier = 10.0
sinkhorn_tol = 0.002
sinkhorn_cumulative_weight = 0.995
sinkhorn_min_weight = 1e-4
sinkhorn_estimated_iters = sum(length(eta_schedule_to(eta)) for eta in sinkhorn_candidate_final_etas) * sinkhorn_max_iters_per_eta
country_work = Dict{eltype(countries_to_process), Int}()
total_work = 0
for _code in countries_to_process
    try
        ne_code = get(ffs, _code, _code)
        work = max(1, nrow(gp[(ne_code,)]) * nrow(gc[(_code,)])) * sinkhorn_estimated_iters
        country_work[_code] = work
        total_work += work
    catch e
        if e isa InterruptException
            rethrow()
        end
        country_work[_code] = 1
        total_work += 1
    end
end

function prepare_country_sinkhorn_problem(owid_code)
    ne_code = get(ffs, owid_code, owid_code)
    mini_cartogram = DataFrame(deepcopy(gc[(owid_code,)]))
    mini_population = DataFrame(gp[(ne_code,)])
    prepared = prepare_sinkhorn2_problem(
        mini_population,
        mini_cartogram;
        cost_power=sinkhorn_cost_power,
    )
    return (
        owid_code = owid_code,
        prepared = prepared,
        country_unit_work = max(1, prepared.sources * prepared.targets),
    )
end

function start_country_prepare_task(country_index)
    if country_index > length(countries_to_process)
        return nothing
    end
    owid_code = countries_to_process[country_index]
    return Threads.@spawn prepare_country_sinkhorn_problem(owid_code)
end

progress = Progress(total_work; desc="Sinkhorn countries: ", showspeed=true);
completed_work = 0
prepare_task = start_country_prepare_task(1)
for country_index in eachindex(countries_to_process)
    _code = countries_to_process[country_index]
    next_prepare_started = false
    try
        prepared_country = fetch(prepare_task)
        prepare_task = start_country_prepare_task(country_index + 1)
        next_prepare_started = true
        owid_code = prepared_country.owid_code
        country_unit_work = prepared_country.country_unit_work
        country_progress = Ref(0)
        progress_callback = () -> begin
            country_progress[] += country_unit_work
            update!(progress, min(completed_work + country_progress[], total_work))
        end
        mini_df, tuning_meta = match_prepared_h3_to_cartogram_sinkhorn2_auto(
         prepared_country.prepared;
         candidate_final_etas = sinkhorn_candidate_final_etas,
         target_rows_multiplier = sinkhorn_target_rows_multiplier,
         max_iters_per_eta = sinkhorn_max_iters_per_eta,
         tol = sinkhorn_tol,
         cumulative_weight = sinkhorn_cumulative_weight,
         min_weight = sinkhorn_min_weight,
         silent = true,
         progress_callback = progress_callback,
         return_metadata = true,
        )
        @info "Sinkhorn eta tuned" code=owid_code final_eta=tuning_meta.final_eta rows=tuning_meta.rows target_rows=tuning_meta.target_rows marginal_error=tuning_meta.marginal_error
        push!(results, mini_df)
    catch (e)
        if e isa InterruptException
            rethrow()
        end
        @warn e
    finally
        if !next_prepare_started
            prepare_task = start_country_prepare_task(country_index + 1)
        end
        completed_work += country_work[_code]
        update!(progress, min(completed_work, total_work))
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

# write the data out for reuse
dropmissing!(toplot, Not([:name, :label]))
Arrow.write("mapping.arrow", toplot[!, [:h3, :x, :y, :weight, :population, :code, :label]]) # the thing we actually want. H3 res = 5
toplot.index = string.(toplot.h3, base=16)

t = combine(groupby(toplot, [:x, :y]), [:weight, :population] => ((w, p) -> sum(w .* p)) => :total_population)
toplot2 = leftjoin(toplot, t, on=[:x, :y])
toplot2.weight_mean = toplot2.weight .* toplot2.population ./ toplot2.total_population
Arrow.write("cartogram_weights.arrow", toplot2[!, [:x, :y, :weight, :population, :code, :label, :index, :weight_mean]])

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
RENDER_SCALE = 10
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:population_z, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, filename="population_check.png", draw_country_borders=true, padding=RENDER_SCALE*10)

# this is the actual map
render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_quantile, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, draw_country_borders=true, padding=RENDER_SCALE*10)
# render_cartogram(almost_there, legend = z -> get(ColorSchemes.Spectral, z), field=:median_z, draw_outline=false, square_size=RENDER_SCALE, font_size=RENDER_SCALE, draw_country_borders=true, padding=RENDER_SCALE*10)

# reducing the resolution makes it tractable
# could we subsample using hilbert?


# ok i think this is promising really
# todo:
# 1) increase neighbours?
# 2) think about subsampling?
# 3) document reuse, move plotting code to library
# 4) attempt first reuse. e.g. vacant properties in france?

# bof. it looks kind of fine in the centre but at the borders it is mega dodge
# fixed with the f32 -> f0 bug. but now it's slow? is it really no faster than the jump solver?
_code = countries[countries.name .== "China", :code][1] # 826 uk # 356 india # 156 china
owid_code = _code
ne_code = get(ffs, owid_code, owid_code)
# gc = groupby(cartogram, :code) # somehow doing this twice causes a segfault
owid_only = setdiff(unique(cartogram.code), ne_countries) # 28 (antigua), 250 (france), 492 (monaco)
# somehow something in here MUTATES the cartogram(!!!!) # switching from csv to arrow fixed it.
mini_cartogram = subdivide_cartogram(cartogram[cartogram.code .== owid_code, :], 1) # do not do this for big countries. lol.
render_cartogram(mini_cartogram)
mini_population = gp[(ne_code,)]
mini_df, tuning_meta = match_h3_to_cartogram_sinkhorn2_auto(
  DataFrame(mini_population),
  DataFrame(mini_cartogram);
  cost_power = 2.0,
  candidate_final_etas = Float32[
      0.001,
      0.0005,
      0.0002,
      0.0001,
      0.00005,
  ],
  target_rows_multiplier = 5.0,
  max_iters_per_eta = 5000,
  tol = 0.002,
  cumulative_weight = 0.995,
  min_weight = 1e-4,
  silent = false,
  return_metadata = true,
)
@show tuning_meta.final_eta
@show tuning_meta.rows
@show tuning_meta.target_rows
@show tuning_meta.marginal_error
# still too stripey for india
# mini_df = match_h3_to_cartogram_ot(mini_population, mini_cartogram, max_neighbors=100, penalty=400.0)
# for reference: soft ot only yields 1,600 matches, compared to ~26,000 with sinkhorn
# i am thinking our best bet is really just to use optimal transport and mask out the parts of the map where the population is too small
# sidequest - integer downsample large countries then upsample back to exact original grid
#
_cities = city_labels_by_h3(cities)
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
RENDER_SCALE = 10 
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
