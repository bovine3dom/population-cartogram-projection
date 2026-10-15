# Arrow.Table can merge replacement dictionaries incorrectly. Check each batch.
using Arrow,SHA,TOML
function verify_stream(reference,candidate,report)
    ispath(report)&&error("report exists")
    digest(path)=bytes2hex(open(sha256,path))
    hashes=map(digest,(reference,candidate));original=Arrow.Table(reference)
    names=propertynames(original);offset=0;batches=0
    for batch in Arrow.Stream(candidate)
        propertynames(batch)==names||error("column names differ")
        count=length(getproperty(batch,first(names)))
        for name in names
            expected,actual=getproperty(original,name),getproperty(batch,name)
            eltype(expected)==eltype(actual)&&length(actual)==count||error("column type or length differs: $name")
            offset+count<=length(expected)||error("extra rows")
            all(isequal(expected[offset+i],actual[i]) for i in eachindex(actual))||error("column values differ: $name at row $offset")
        end
        offset+=count;batches+=1
    end
    offset==length(getproperty(original,first(names)))||error("missing rows")
    map(digest,(reference,candidate))==hashes||error("input changed during verification")
    result=Dict("reference_sha256"=>hashes[1],"stream_sha256"=>hashes[2],"rows"=>offset,"batches"=>batches,
        "reference_bytes"=>filesize(reference),"stream_bytes"=>filesize(candidate),"reader"=>"Arrow.Stream", "all_columns_equal"=>true)
    mkpath(dirname(report));open(io->TOML.print(io,result),report,"w");result
end
if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==3||error("usage: verify_stream.jl REFERENCE_ARROW STREAM_ARROW NEW_REPORT")
    println(verify_stream(ARGS...))
end
