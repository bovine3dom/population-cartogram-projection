using Serialization
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame

length(ARGS)==1 || error("usage: inspect_study.jl STUDY_DIRECTORY")
dir=ARGS[1]
countries=deserialize(joinpath(dir,"countries.jls"))
rows=NamedTuple[]
for name in sort(readdir(dir))
    trial=joinpath(dir,name)
    isdir(trial) || continue
    for stage in ("baseline","candidate")
        path=joinpath(trial,"$stage.jls")
        isfile(path) || continue
        plans=deserialize(path)
        orientation=ContinuityDiagnostics.orientations(countries,plans)
        CSV.write(joinpath(trial,"$stage-orientation.csv"),orientation)
        for r in eachrow(orientation)
            push!(rows,(;name,stage,NamedTuple(r)...))
        end
        GC.gc()
    end
end
CSV.write(joinpath(dir,"fold-areas.csv"),DataFrame(rows))
println("Wrote $(joinpath(dir,"fold-areas.csv"))")
