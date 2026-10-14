using Test
include("../examples/continuity/refit_tuned.jl")

@testset "Checked tuned refit" begin
    source=DataFrame(id=UInt64.(1:4),x=[-1.,1.,-1.,1.],y=[49.,49.,51.,51.],value=[1.,2.,3.,4.])
    target=DataFrame(x=[0,2,0,2],y=[0,0,2,2]);problem=CE.PCP._prepare_problem(target,source)
    xyz=hcat([[cosd(y)*cosd(x),cosd(y)*sind(x),sind(y)] for (x,y) in zip(source.x,source.y)]...)
    c=(;code=1,source,target,problem,xyz,cost=CE.GeometryCost(problem),a=source.value./sum(source.value),b=fill(.25,4))
    mktempdir() do root
        input=joinpath(root,"parent");tuned=joinpath(root,"tuned");out=joinpath(root,"refit")
        mkpath(input);mkpath(joinpath(tuned,"1"))
        CE.checkpoint(joinpath(input,"countries.jls"),[c])
        CE.run_case([c],CE.KA.CPU(),joinpath(input,"fit");compact=true,eta=.02,strength=0.,
            borders=Set{Tuple{Int,Int}}(),inner_tolerance=1e-6,outer_steps=1,export_arrow=false)
        entry=CE.compact_tune(c,CE.KA.CPU();etas=[.02],tolerance=1e-6)
        CE.checkpoint(joinpath(tuned,"1","selected.jls"),entry)
        CSV.write(joinpath(tuned,"selection.csv"),DataFrame(code=[1],angle=[0]))
        @test_throws ErrorException refit_tuned(input,tuned,out;backend=CE.KA.CPU())
        write(joinpath(tuned,"tuning-complete.txt"),"test calibration\n")
        rows=refit_tuned(input,tuned,out;backend=CE.KA.CPU(),outer_steps=1)
        @test last(rows).iteration==1
        @test isfile(joinpath(out,"fit","pass-1.jls"))
        @test isfile(joinpath(out,"research-fit-complete.txt"))
        @test !isfile(joinpath(out,"fit-complete.txt"))
        saved=CE.saved_case(joinpath(out,"fit"),[c]).settings
        @test saved[:country_etas]==Dict(1=>.02)
        @test saved[:max_damping]==1 && saved[:compact_retry_factor]==256
        @test_throws ErrorException refit_tuned(input,tuned,out;backend=CE.KA.CPU())
        @test_throws ErrorException refit_tuned(input,tuned,joinpath(root,"bad");backend=CE.KA.CPU(),outer_steps=0)
        CE.checkpoint(joinpath(tuned,"1","eta-0.02.jls"),entry.result)
        CE.checkpoint(joinpath(tuned,"1","selected.jls"),merge(entry,(;support=(;rows=999))))
        fallback=joinpath(root,"fallback")
        refit_tuned(input,tuned,fallback;backend=CE.KA.CPU(),outer_steps=1)
        @test only(CSV.read(joinpath(fallback,"selection.csv"),DataFrame).eta)==.02
        CE.checkpoint(joinpath(tuned,"1","selected.jls"),merge(entry,(;eta=.01)))
        @test_throws ErrorException refit_tuned(input,tuned,joinpath(root,"bad");backend=CE.KA.CPU())
        @test !ispath(joinpath(root,"bad"))
    end
end
