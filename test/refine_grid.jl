using Test
include("../examples/continuity/refine_grid.jl")

function refinement_fixture()
    source=DataFrame(id=UInt64.(1:4),x=[-40.,-20.,20.,40.],y=[-10.,10.,-10.,10.],value=ones(4))
    target=DataFrame(x=[0,2],y=[0,0])
    xyz=hcat([[cosd(y)*cosd(x),cosd(y)*sind(x),sind(y)] for (x,y) in zip(source.x,source.y)]...)
    function country(target)
        problem=CE.PCP._prepare_problem(target,source)
        (;code=1,source,target,problem,xyz,cost=CE.GeometryCost(problem),a=fill(.25,4),b=fill(1/size(target,1),size(target,1)))
    end
    coarse=country(target);fine=country(refinement_target(target,2))
    # Deliberately reversed coarse transport. A true fine fit must release it.
    plan=[0. .25;0. .25;.25 0.;.25 0.]
    (;coarse,fine,plan)
end

backends=Any[CE.KA.CPU()]
if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
    @test oneAPI.functional()
    push!(backends,oneAPI.oneAPIBackend())
end
@testset "Removed subdivision command" begin
    mktempdir() do root
        out=joinpath(root,"output")
        script=joinpath(@__DIR__,"..","examples","continuity","subdivide_native.jl")
        @test !success(pipeline(`$(Base.julia_cmd()) $script missing-input 2 $out`;stdout=devnull,stderr=devnull))
        @test !ispath(out)
    end
end
@testset "Fine-grid settings and geometry" begin
    c=refinement_fixture().coarse
    @test_throws ErrorException refinement_target(c.target,1)
    @test_throws ErrorException refinement_target(vcat(c.target,c.target),2)
    s=Dict(:eta=>.02,:country_etas=>Dict(1=>.01),:start_step=>12,
        :internal_scale=>2.,:border_scale=>3.,:fold_strength=>4.,:fold_smoothing=>8.)
    f=refinement_settings(s,2;outer_steps=3)
    @test f[:start_step]==1 && f[:outer_steps]==3 && f[:compact]
    @test !f[:anneal] && !f[:matrix_free] && !haskey(f,:country_etas)
    @test (f[:internal_scale],f[:border_scale],f[:fold_strength],f[:fold_smoothing])==(8.,6.,16.,2.)
    @test s[:start_step]==12 && s[:country_etas]==Dict(1=>.01)
    @test_throws ErrorException refinement_settings(s,2;outer_steps=0)
    target=refinement_target(c.target,2)
    @test size(target,1)==8 && allunique(zip(target.x,target.y))
    @test target.parent_cell_id==repeat(1:2;inner=4)
    cut=merge(c,(;cut_targets=Set([(0.,0.)])))
    @test refinement_cuts(cut,2)==Set([(-1.,-1.),(-1.,1.),(1.,-1.),(1.,1.)])
    # Fine adjacency crosses the old parent boundary.
    d=refinement_fixture().fine
    @test any(e->target.parent_cell_id[e[2]]!=target.parent_cell_id[e[4]],CE.graph([d]))
    shifted=copy(d.target);shifted.x.+=8
    adjacent=merge(d,(;code=2,target=shifted))
    borders=Set([(1,2)])
    @test count(e->e[1]!=e[3],CE.graph([d,adjacent];borders))==2
    @test count(e->e[1]!=e[3],CE.graph([d,adjacent];borders=Set()))==0
    @test count(e->e[1]!=e[3],CE.graph([merge(d,(;cut_targets=Set([(5,-1),(5,1)]))),adjacent];borders))==0
end
for backend in backends
    @testset "Fine fit releases coarse allocations: $backend" begin
        (;coarse,fine,plan)=refinement_fixture()
        settings=Dict(:eta=>.05,:strength=>0.,:inner_tolerance=>1e-6,
            :spread_limit=>Inf,:interior_limit=>Inf,:max_damping=>1.,:proximal=>0.,:accelerate=>true)
        mktempdir() do root
            out=joinpath(root,"fine")
            rows=fit_refined([coarse],[plan],[fine],backend,out;factor=2,settings,
                borders=Set{Tuple{Int,Int}}(),etas=[.05],outer_steps=1)
            p=only(deserialize(joinpath(out,"fit","candidate.jls")))
            baseline=only(deserialize(joinpath(out,"baseline.jls")))
            @test p isa CE.CompactPlan
            @test Matrix(p)≈Matrix(baseline) atol=2e-5
            collapsed=hcat([vec(sum(Matrix(p)[:,(j-1)*4+1:j*4];dims=2)) for j in 1:2]...)
            @test maximum(abs.(collapsed.-plan))>.1
            @test any(collapsed[plan.==0].>.1)
            @test vec(sum(p;dims=2))≈fine.a atol=1e-10
            @test maximum(abs.(vec(sum(p;dims=1))./fine.b.-1))<.001
            @test last(rows).iteration==1
            @test isfile(joinpath(out,"research-fit-complete.txt"))
            @test !isfile(joinpath(out,"fit-complete.txt"))
            saved=CE.saved_case(joinpath(out,"fit"),[fine]).settings
            @test saved[:country_etas]==Dict(1=>.05)
            @test saved[:start_step]==1 && saved[:compact]
            @test_throws ErrorException fit_refined([coarse],[plan],[fine],backend,out;
                factor=2,settings,borders=Set{Tuple{Int,Int}}())
            cut=merge(coarse,(;cut_targets=Set([(0.,0.)])))
            @test_throws ErrorException fit_refined([cut],[plan],[fine],backend,joinpath(root,"bad");
                factor=2,settings,borders=Set{Tuple{Int,Int}}())
            @test !ispath(joinpath(root,"bad"))
            if backend isa CE.KA.CPU
                # Exercise the file runner with new native sources, not the
                # coarse source IDs or source-to-parent marginal constraints.
                input=joinpath(root,"coarse");sources=joinpath(root,"sources")
                mkpath(joinpath(input,"fit"));mkpath(sources)
                CE.checkpoint(joinpath(input,"countries.jls"),[coarse])
                CE.checkpoint(joinpath(input,"fit","candidate.jls"),[plan])
                cp(joinpath(out,"fit","settings.csv"),joinpath(input,"fit","settings.csv"))
                ids=[CE.H3.API.latLngToCell(CE.H3.Lib.LatLng(deg2rad(y),deg2rad(x)),6)
                    for (x,y) in zip([-40.,-20.,0.,20.,40.],[-10.,10.,0.,-10.,10.])]
                CE.Arrow.write(joinpath(sources,"country-1-res6.arrow"),
                    DataFrame(id=ids,country_code=fill(1,5),population=[1.,2.,1.,2.,1.]))
                dest=joinpath(root,"native-fine")
                refine_grid(input,"fit",sources,dest,6,2;backend,etas=[.05],outer_steps=1)
                d=only(deserialize(joinpath(dest,"countries.jls")))
                @test d.source.id==ids && length(d.a)==5 && length(d.b)==8
                @test d.a≈[1.,2.,1.,2.,1.]./7
                @test isfile(joinpath(dest,"research-fit-complete.txt"))
                @test occursin("Resolution: 6",read(joinpath(dest,"provenance.txt"),String))
            end
        end
    end
end
