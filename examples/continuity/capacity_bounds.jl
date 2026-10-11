using Serialization
include("experiment.jl")
include("diagnostics.jl")
using .ContinuityExperiment: CSV, DataFrame
const CE=ContinuityExperiment

length(ARGS)>=4 || error("usage: capacity_bounds.jl STUDY_DIRECTORY BORDER_CSV NEW_OUTPUT.csv FACTORS...")
input,mask,output=ARGS[1:3]
ispath(output) && error("refusing to overwrite $output")
countries=deserialize(joinpath(input,"countries.jls"))
raw=CSV.read(mask,DataFrame)
borders=Set(minmax(r.country_a,r.country_b) for r in eachrow(raw))
tables=DataFrame[]
for factor in parse.(Int,ARGS[4:end])
    factor>=1 || error("invalid subdivision")
    refined=map(countries) do c
        target=DataFrame([(x=factor*r.x+2ix-factor-1,y=factor*r.y+2iy-factor-1)
                          for r in eachrow(c.target) for iy in 1:factor for ix in 1:factor])
        (;code=c.code,xyz=c.xyz,a=c.a,b=fill(1/length(target.x),length(target.x)),target)
    end
    result=ContinuityDiagnostics.capacity_rms_bounds(refined,CE.graph(refined;borders))
    result.subdivision=fill(factor,size(result,1))
    push!(tables,result)
    println("Completed subdivision $factor")
end
CSV.write(output,vcat(tables...))
