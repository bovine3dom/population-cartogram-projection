using Test
include("../examples/continuity/audit_sharpness.jl")

@testset "Sharpness checkpoint audit" begin
    source=DataFrame(id=UInt64.(1:4),x=[-1.,1.,-1.,1.],y=[49.,49.,51.,51.],value=[1.,2.,3.,4.])
    target=DataFrame(x=[0,2,0,2],y=[0,0,2,2])
    problem=CE.PCP._prepare_problem(target,source)
    xyz=hcat([[cosd(y)*cosd(x),cosd(y)*sind(x),sind(y)] for (x,y) in zip(source.x,source.y)]...)
    c=(;code=1,source,target,problem,xyz,cost=CE.GeometryCost(problem),a=source.value./sum(source.value),b=fill(.25,4))
    mktempdir() do root
        CE.checkpoint(joinpath(root,"countries.jls"),[c])
        CE.run_case([c],CE.KA.CPU(),joinpath(root,"fit");compact=true,eta=.02,strength=0.,
            borders=Set{Tuple{Int,Int}}(),inner_tolerance=1e-6,save_passes=true,outer_steps=1,export_arrow=false)
        baseline=only(deserialize(joinpath(root,"fit","baseline.jls")))
        original=CS.plan_rows(c,baseline,(p,r)->exp.(CE.logblock(p,r)))
        reference=joinpath(root,"original.csv");CSV.write(reference,DataFrame(original))
        checkpoint=joinpath(root,"fit","pass-1.jls");report=joinpath(root,"audit.toml")
        result=audit_sharpness(root,checkpoint,reference,report)
        @test result["iteration"]==1
        @test result["source"]["sources"]==4
        @test result["source"]["connections995"]==result["original_source"]["connections995"]
        @test isfile(report*".sources.csv")
        @test isfile(report*".orientations.csv")
        @test_throws ErrorException audit_sharpness(root,checkpoint,reference,report)
        saved=deserialize(checkpoint);metrics=copy(saved.metrics)
        metrics[end]=merge(last(metrics),(;objective=last(metrics).objective+1))
        bad=joinpath(root,"bad.jls");CE.checkpoint(bad,merge(saved,(;metrics)))
        @test_throws ErrorException audit_sharpness(root,bad,reference,joinpath(root,"bad.toml"))
        @test !ispath(joinpath(root,"bad.toml"))
        original[1]=merge(first(original),(;population=2first(original).population))
        CSV.write(reference,DataFrame(original))
        @test_throws ErrorException audit_sharpness(root,checkpoint,reference,joinpath(root,"changed-input.toml"))
    end
end
