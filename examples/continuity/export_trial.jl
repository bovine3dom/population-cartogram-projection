using Serialization
include("experiment.jl")
using .ContinuityExperiment: Arrow, CSV, DataFrame, H3, groupby, transform!

length(ARGS)==3 || error("usage: export_trial.jl COUNTRIES.jls TRIAL_DIRECTORY OUTPUT_DIRECTORY")
countries=deserialize(ARGS[1])
trial,outdir=abspath.(ARGS[2:3])
ispath(outdir) && error("refusing to overwrite $outdir")
mkpath(outdir)
population=Dict{UInt64,Float64}()
for c in countries,r in eachrow(c.source)
    population[r.id]=get(population,r.id,0.)+r.value
end
ids=sort!(collect(keys(population)))
Arrow.write(joinpath(outdir,"population_density_hilo.arrow"),(
    index_lower=UInt32.(ids .& 0xffffffff),index_upper=UInt32.(ids .>> 32),
    value=[population[id]/H3.API.cellAreaKm2(id) for id in ids]))
for name in ("baseline","candidate")
    plans=deserialize(joinpath(trial,"$name.jls"))
    raw=joinpath(outdir,"$name.arrow")
    ContinuityExperiment.export_mapping(raw,countries,plans;retained=.99999)
    frame=DataFrame(Arrow.Table(raw);copycols=true)
    transform!(groupby(frame,[:x,:y]),:weight_mean=>(v->v./sum(v))=>:weight_mean)
    frame.population=[population[id] for id in frame.id]
    frame.index_lower=UInt32.(frame.id .& 0xffffffff)
    frame.index_upper=UInt32.(frame.id .>> 32)
    frame.label=Vector{Union{Missing,String}}(missing,size(frame,1))
    frame.prominence=Vector{Union{Missing,Float64}}(missing,size(frame,1))
    Arrow.write(joinpath(outdir,"$(name)_hilo.arrow"),frame)
    rows=NamedTuple[]
    for (c,p) in zip(countries,plans)
        q=ContinuityExperiment.means(c,p)
        for j in axes(q,2)
            v=q[:,j]/sqrt(sum(abs2,q[:,j]))
            push!(rows,(;x=c.target.x[j],y=c.target.y[j],code=c.code,
                        longitude=rad2deg(atan(v[2],v[1])),latitude=rad2deg(asin(v[3]))))
        end
    end
    CSV.write(joinpath(outdir,"$name-centres.csv"),DataFrame(rows))
    println("Exported $name: $(size(frame,1)) rows")
end
