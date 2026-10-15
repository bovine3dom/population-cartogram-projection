using Test
include("../examples/auto-cartogram/promote_h3_recovery.jl")

@testset "Interrupted border checkpoint validation" begin
    countries=map(1:2) do code
        source=DataFrame(id=["$code:$i" for i in 1:4],x=[0.,1.,0.,1.].+code,y=[49.,49.,50.,50.],value=[1.,2.,3.,4.])
        target=DataFrame(x=[0,2,0,2].+4code,y=[0,0,2,2])
        problem=CE.PCP._prepare_problem(target,source)
        xyz=hcat([[cosd(y)*cosd(x),cosd(y)*sind(x),sind(y)] for (x,y) in zip(source.x,source.y)]...)
        (;code,source,target,problem,xyz,cost=CE.GeometryCost(problem),a=source.value./sum(source.value),b=fill(.25,4))
    end
    mktempdir() do root
        fit=joinpath(root,"fit")
        CE.checkpoint(joinpath(root,"countries.jls"),countries)
        CE.run_case(countries,CE.KA.CPU(),fit;compact=true,country_etas=Dict(1=>.002,2=>.002),
            borders=Set([(1,2)]),border_share=.25,strength=.001,outer_steps=0,coordinate=true,export_arrow=false)
        rows=CSV.read(joinpath(fit,"metrics.csv"),DataFrame)
        row=merge(NamedTuple(rows[1,:]),(;iteration=1,updated_country=1,accepted=false))
        push!(rows,row);CSV.write(joinpath(fit,"metrics.csv"),rows)
        state=interrupted_state(root)
        @test state.completed==1
        @test state.countries[state.order[2]].code==2
        @test all(all(isfinite,g) for g in state.forces)
        @test plan_digest(state.seed[1])==plan_digest(deepcopy(state.seed[1]))
        path=joinpath(root,"inspection");inspect(root,path)
        @test JSON.parsefile(joinpath(path,"inspection.json"))["checkpoint_matches_metrics"]
        @test_throws ErrorException inspect(root,path)
        CE.checkpoint(joinpath(path,"accepted.jls"),(;plans=state.seed,updated_country=2,proximal=1000.,damping=1.,objective=rows[end,:objective],metrics=CE.metrics(countries,state.seed,state.edges)))
        @test_throws ErrorException promote(root,path,joinpath(root,"invalid-promotion"))
        @test !ispath(joinpath(root,"invalid-promotion"))
        rows.cross_rms_all[end]+=1;CSV.write(joinpath(fit,"metrics.csv"),rows)
        @test_throws ErrorException interrupted_state(root)
        rows.cross_rms_all[end]-=1;rows.updated_country[end]=2;CSV.write(joinpath(fit,"metrics.csv"),rows)
        @test_throws ErrorException interrupted_state(root)
    end
end
