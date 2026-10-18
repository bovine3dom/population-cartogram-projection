using OWIDLayout
2<=length(ARGS)<=4 || error("Usage: fit-mapping.jl BUILD_DIR MAPPING_DIR [RESOLUTION=5] [--resume]")
resolution=length(ARGS)>=3 ? parse(Int,ARGS[3]) : 5
length(ARGS)<4 || ARGS[4]=="--resume" || error("Expected --resume")
OWIDLayout.fit_export(ARGS[1],ARGS[2];resolution,resume=length(ARGS)==4)
println("Complete: ",joinpath(ARGS[2],"h3-mon"))
