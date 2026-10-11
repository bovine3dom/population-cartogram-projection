using Test
include(joinpath(@__DIR__, "..", "examples", "continuity", "experiment.jl"))
using .ContinuityExperiment
const CE = ContinuityExperiment
include(joinpath(@__DIR__,"..","examples","continuity","diagnostics.jl"))
const CD = ContinuityDiagnostics

@testset "Experimental dense Sinkhorn" begin
    c = [0.0 0.8 0.2; 0.7 0.0 0.4]
    a, b = [0.4,0.6], [0.2,0.3,0.5]
    result = CE.sinkhorn(c,a,b,CE.KA.CPU(); eta=.1,tolerance=1e-6)
    @test vec(sum(result.plan;dims=2)) ≈ a atol=1e-12
    @test vec(sum(result.plan;dims=1)) ≈ b atol=1e-6
    @test all(isfinite,result.plan)
    independent = CE.sinkhorn(zeros(2,3),a,b,CE.KA.CPU();eta=.1,tolerance=1e-6)
    @test independent.plan ≈ a * transpose(b) atol=1e-6
    @test log(result.plan[1,1]*result.plan[2,2]/(result.plan[1,2]*result.plan[2,1])) ≈
          -(c[1,1]+c[2,2]-c[1,2]-c[2,1])/.1 atol=1e-5
    offset = CE.sinkhorn(c .+ [5.0 1.0 -3.0],a,b,CE.KA.CPU();eta=.1,tolerance=1e-6)
    @test offset.plan ≈ result.plan atol=1e-6
    warm = CE.sinkhorn(c .+ [5.0 1.0 -3.0],a,b,CE.KA.CPU();eta=.1,tolerance=1e-6,
                      initial_beta=result.beta)
    @test warm.plan ≈ offset.plan atol=1e-6
    proximal=CE.sinkhorn(c .- .2log.(result.plan),a,b,CE.KA.CPU();eta=.3,tolerance=1e-6)
    @test proximal.plan ≈ result.plan atol=1e-6
    annealed=CE.sinkhorn(c,a,b,CE.KA.CPU();eta=.1,tolerance=1e-6,anneal=true)
    @test annealed.plan ≈ result.plan atol=1e-6
    @test only(CE.anderson_candidate([[.5],[.75]],[[.5],[.25]])) ≈ 1 atol=1e-9
    sharp=CE.sinkhorn(c,a,b,CE.KA.CPU();eta=.01,tolerance=1e-6)
    accelerated=CE.sinkhorn(c,a,b,CE.KA.CPU();eta=.01,tolerance=1e-6,accelerate=true)
    @test accelerated.plan ≈ sharp.plan atol=1e-6
    @test_throws ErrorException CE.sinkhorn(c,a,b,CE.KA.CPU();maxiters=1)
    if get(ENV,"CONTINUITY_GPU_TEST","") == "1"
        @eval using oneAPI
        @test oneAPI.functional()
        gpu = CE.sinkhorn(c,a,b,oneAPI.oneAPIBackend();eta=.1,tolerance=1e-6)
        @test gpu.plan ≈ result.plan atol=1e-6
        accelerated_gpu=CE.sinkhorn(c,a,b,oneAPI.oneAPIBackend();eta=.01,tolerance=1e-6,accelerate=true,anneal=true)
        @test accelerated_gpu.plan ≈ sharp.plan atol=1e-6
    end
end

@testset "GPU-compatible marginal refinement" begin
    kernel=[.1 .3;.3 .3]
    a,b=[.4,.6],[.5,.5]
    expected=CE.sinkhorn(-log.(kernel),a,b,CE.KA.CPU();eta=1.,tolerance=1e-6)
    result=CE.polish_plan(kernel,a,b,CE.KA.CPU();tolerance=1e-6)
    @test !isnothing(result)
    @test result.plan ≈ expected.plan atol=1e-6
    @test vec(sum(result.plan;dims=2)) ≈ a atol=1e-12
    @test isnothing(CE.polish_plan(kernel,a,b,CE.KA.CPU();maxiters=1))
    if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
        gpu=CE.polish_plan(kernel,a,b,oneAPI.oneAPIBackend();tolerance=1e-6)
        @test gpu.plan ≈ expected.plan atol=1e-6
    end
end

@testset "Matrix-free geographic forces" begin
    source=CE.DataFrame(id=[1,2],x=[.1,.2],y=[0.,.1],value=[.4,.6])
    target=CE.DataFrame(x=[0,2,4],y=[0,0,0])
    problem=CE.PCP._prepare_problem(target,source)
    cost=[CE.PCP._cost(problem,i,j) for i in 1:2,j in 1:3]
    xyz=[cos(.1) cos(.2);sin(.1) sin(.2);0. 0.]
    c=(;source,target,problem,cost,xyz,a=[.4,.6],b=fill(1/3,3))
    forces=[.1 .2 .3;.5 -.2 .1;.2 .8 -.5]
    dense=cost+transpose(xyz.-CE.mean(xyz;dims=2))*forces
    expected=CE.sinkhorn(dense,c.a,c.b,CE.KA.CPU();eta=.1,tolerance=1e-6)
    result=CE.feature_sinkhorn(c,forces,CE.KA.CPU();eta=.1,tolerance=1e-6)
    @test result.plan ≈ expected.plan atol=1e-6
    if get(ENV,"CONTINUITY_GPU_TEST","")=="1"
        gpu=CE.feature_sinkhorn(c,forces,oneAPI.oneAPIBackend();eta=.1,tolerance=1e-6)
        @test gpu.plan ≈ expected.plan atol=1e-6
    end
end

@testset "Explicit international seams" begin
    countries = [(code=code,target=CE.DataFrame(x=[x],y=[0]))
                 for (code,x) in [(24,0),(180,2),(894,4)]]
    @test isempty(CE.graph(countries))
    @test CE.graph(countries;borders=Set([(24,180),(180,894)])) == [(1,1,2,1),(2,1,3,1)]
    edges = [(1,1,1,2),(1,2,1,3),(1,3,2,1)]
    @test CE.edge_weights(edges,.8) ≈ [.1,.1,.8]
    @test sum(CE.edge_weights(edges,nothing)) ≈ 1
    @test_throws ErrorException CE.edge_weights(edges,1.1)
    @test_throws ErrorException CE.edge_weights(edges[1:2],.8)
end

@testset "Capacity bounds and orientation" begin
    countries = [(code=k,xyz=reshape([cos(a),sin(a),0.0],3,1),a=[1.0],b=[.5,.5])
                 for (k,a) in enumerate((0.0,.1))]
    bounds = CD.nearest_supply(countries,[(1,2,2,1)])
    @test bounds.mean_nearest_lower_bound_km ≈ [637.1,637.1]
    @test bounds.population_fraction == [.5,.5]
    xyz=hcat([[cos(lat)*cos(lon),cos(lat)*sin(lon),sin(lat)]
              for (lon,lat) in ((0.,.01),(.01,.01),(0.,0.),(.01,0.))]...)
    c=(code=24,xyz=xyz,target=CE.DataFrame(x=[0,2,0,2],y=[0,0,2,2]))
    p=Matrix{Float64}(CE.I,4,4)/4
    @test CD.orientations([c],[p]).positive == [0]
    @test CD.orientations([c],[p]).negative == [2]
    reversed=CD.orientations([c],[p[:,[1,3,2,4]]])
    @test reversed.positive == [2]
    @test reversed.positive_area_km2 ≈ CD.orientations([c],[p]).negative_area_km2
    @test only(reversed.maximum_positive_area_km2) > 1
    faces=CE.triangles([c])
    @test length(faces)==2
    @test first(CE.fold_penalty_gradient([c],[p],faces))==0
    inverted=.9p[:,[1,3,2,4]].+.1/16
    value,g=CE.fold_penalty_gradient([c],[inverted],faces)
    @test value>0
    direction=zeros(4,4); direction[1,2]=.05
    h=1e-6
    plus=first(CE.fold_penalty_gradient([c],[inverted+h*direction],faces))
    minus=first(CE.fold_penalty_gradient([c],[inverted-h*direction],faces))
    @test (plus-minus)/(2h) ≈ sum(only(g).*direction) rtol=1e-5
end

@testset "Coarse geographic field refinement" begin
    xyz=[1. 1. 1. 1.; 0. .01 0. .01; 0. 0. .01 .01]
    xyz ./= sqrt.(sum(abs2,xyz;dims=1))
    target=CE.DataFrame(x=[0,2,0,2],y=[0,0,2,2],parent_cell_id=string.(1:4))
    coarse=(;xyz,target)
    plan=Matrix{Float64}(CE.I,4,4)/4
    @test CE.refined_centres(coarse,plan,coarse) ≈ xyz
    fine=(target=CE.DataFrame([(x=2r.x+dx,y=2r.y+dy,parent_cell_id=r.parent_cell_id)
                              for r in eachrow(target) for dx in (-1,1) for dy in (-1,1)]),)
    q=CE.refined_centres(coarse,plan,fine)
    expected=xyz[:,1]-.25(xyz[:,2]-xyz[:,1])-.25(xyz[:,3]-xyz[:,1])
    @test q[:,1] ≈ expected/CE.norm(expected)
    @test vec(sum(abs2,q;dims=1)) ≈ ones(16)
    @test CD.orientations([(code=1,xyz=q,target=fine.target)],[CE.Diagonal(fill(1/16,16))]).positive == [0]
    @test_throws ErrorException CE.refined_centres(coarse,plan,(target=fine.target[1:15,:],))
end

@testset "Atomic plan checkpoints" begin
    mktempdir() do dir
        path=joinpath(dir,"plan.jls")
        CE.checkpoint(path,[1.,2.])
        @test CE.deserialize(path)==[1.,2.]
        CE.checkpoint(path,[3.,4.])
        @test CE.deserialize(path)==[3.,4.]
        @test !ispath(path*".tmp")
    end
end

@testset "Shared parent export" begin
    countries=[(code=k,source=CE.DataFrame(id=UInt64[1],value=[v]),a=[1.],
                target=CE.DataFrame(x=[2k],y=[0])) for (k,v) in enumerate((20.,80.))]
    mktempdir() do dir
        path=joinpath(dir,"mapping.arrow")
        CE.export_mapping(path,countries,[ones(1,1),ones(1,1)])
        result=CE.DataFrame(CE.Arrow.Table(path))
        @test result.weight ≈ [.2,.8]
        @test result.weight_mean == [1.,1.]
    end
end

@testset "Local border metrics" begin
    countries = [(xyz=[cos(a) cos(a+.01); sin(a) sin(a+.01); 0.0 0.0],b=[.5,.5])
                 for a in (0.0,.02)]
    plans = [[.5 0.; 0. .5],[.5 0.; 0. .5]]
    edges = [(1,1,1,2),(1,2,2,1),(2,1,2,2)]
    m = CE.metrics(countries,plans,edges)
    @test m.seam_p50 ≈ m.local_p50 rtol=1e-8
    @test m.cross_rms_p50 ≈ m.local_rms_p50 rtol=1e-8
    @test m.local_p50 ≈ 63.71 rtol=1e-8
    @test m.spread_mean < .001
end

@testset "Continuity gradient and permitted cuts" begin
    xyz = [1.0 cos(.01); 0.0 sin(.01); 0.0 0.0]
    countries = [(;xyz,b=[.5,.5])]
    p = [[.4 .1; .1 .4]]
    edges = [(1,1,1,2)]
    value, gradients = CE.penalty_gradient(countries,p,edges)
    for form in (:mean,:distribution), saturating in (true,false),
        reference in (nothing, [xyz .* [.8 .9]]),
        direction in ([.1 -.1; -.1 .1], [.2 .1; .3 -.1])
        h = 1e-6
        _, gradient = CE.penalty_gradient(countries,p,edges;form,saturating,reference)
        plus, _ = CE.penalty_gradient(countries,[p[1]+h*direction],edges;form,saturating,reference)
        minus, _ = CE.penalty_gradient(countries,[p[1]-h*direction],edges;form,saturating,reference)
        @test (plus-minus)/(2h) ≈ sum(gradient[1].*direction) rtol=1e-4
    end
    @test CE.means(only(countries), 1.001p[1]) ≈ CE.means(only(countries),p[1])
    mixed = [[.25 .25; .25 .25]]
    mixed_mean, _ = CE.penalty_gradient(countries,mixed,edges)
    mixed_distribution, _ = CE.penalty_gradient(countries,mixed,edges;form=:distribution)
    @test mixed_mean == 0
    @test mixed_distribution > 0
    internal_mean,internal_gradient=CE.penalty_gradient(countries,p,edges;form=:distribution,internal_form=:mean)
    @test internal_mean ≈ value
    @test only(internal_gradient) ≈ only(gradients)
    @test_throws ErrorException CE.penalty_gradient(countries,p,edges;internal_form=:unknown)
    _, forces = CE.penalty_gradient(countries,p,edges;forces_only=true)
    difference=only(gradients)-transpose(xyz)*only(forces)
    @test maximum(abs,maximum(difference;dims=1)-minimum(difference;dims=1)) < 1e-10
    weighted, wg = CE.penalty_gradient(countries,p,edges;weights=[.2])
    @test weighted ≈ .2value
    @test only(wg) ≈ .2only(gradients)
    @test 0 < value < 1
    far = [(;xyz=[1.0 -1.0; 0.0 0.0; 0.0 0.0],b=[.5,.5])]
    penalty, gradient = CE.penalty_gradient(far,[[.5 0.; 0. .5]],edges)
    @test penalty ≈ 1
    @test maximum(abs,only(gradient)) < 1e-10
    empty_penalty, empty_gradient = CE.penalty_gradient(countries,p,Tuple{Int,Int,Int,Int}[])
    @test empty_penalty == 0
    @test all(iszero,only(empty_gradient))
end
