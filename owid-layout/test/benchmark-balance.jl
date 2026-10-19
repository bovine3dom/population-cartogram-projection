# Optional benchmark against the saved pre-fix implementation and a raw shard.
using OWIDLayout, CSV, DataFrames, JSON
length(ARGS)==3 || error("Usage: benchmark-balance.jl OLD_MAPPING_FIT.jl RAW_SHARD_DIR REPORT.json")
oldcode,root,report=ARGS
module PreviousBalance
using DataFrames
const EDGE_OFFSETS=((-1,0),(1,0),(0,-1),(0,1))
end
include_string(PreviousBalance,first(split(read(oldcode,String),"function check_mapping")),oldcode)
s=CSV.read(joinpath(root,"sources.csv"),DataFrame)
t=CSV.read(joinpath(root,"targets.csv"),DataFrame)
r=CSV.read(joinpath(root,"mapping.csv"),DataFrame)
function bounded(f,r,s,t,n)
    try
        f(r,s,t;iterations=n,expansion_steps=0,tolerance=1e-6)
    catch e
        occursin("Sparse balance failed",sprint(showerror,e)) || rethrow()
    end
end
results=Dict{String,Any}()
for (name,f) in (("before",PreviousBalance.balance_mapping),("after",OWIDLayout.balance_mapping))
    bounded(f,r,s,t,1)
    run=@timed bounded(f,r,s,t,100)
    results[name]=Dict("iterations"=>100,"seconds"=>run.time,"allocated_bytes"=>run.bytes)
    println(name,": ",results[name]);flush(stdout)
end
run=@timed OWIDLayout.balance_mapping(r,s,t)
mapping,balance=run.value
results["full_balance"]=merge(balance,OWIDLayout.check_mapping(mapping,s,t),Dict("seconds"=>run.time))
results["inputs"]=Dict(p=>OWIDLayout.file_digest(p) for p in (oldcode,joinpath(root,"sources.csv"),joinpath(root,"targets.csv"),joinpath(root,"mapping.csv")))
OWIDLayout.write_json_atomic(report,results)
println("Full balance: ",results["full_balance"])
