using Test
include("../examples/auto-cartogram/audit_h3_borders.jl")

@testset "Exact component border mask" begin
    mktempdir() do root
        original=joinpath(root,"original");mkpath(joinpath(original,"labels"))
        CSV.write(joinpath(original,"groups.csv"),DataFrame(component_id=["A","B","C"],group_id=["A","B","C"]))
        CSV.write(joinpath(original,"targets.csv"),DataFrame(group_id=["A","A","B","B","C","C"],x=[0,1,2,3,0,1],y=[0,0,0,0,1,1]))
        # The same H3 parent in two components must remain two source rows.
        CSV.write(joinpath(original,"sources.csv"),DataFrame(id=["A:599552292856791039","B:599552292856791039","C:599552292856791039"],component_id=["A","B","C"],group_id=["A","B","C"],value=[30.,70.,20.],x=[1.,1.,1.],y=[1.,1.,1.]))
        contacts=joinpath(root,"contacts.csv")
        CSV.write(contacts,DataFrame(a=["A","A","B"],b=["B","unrepresented-island","C"]))
        out=joinpath(root,"prepared");prepare_groups(original,contacts,out;expected_tiles=6)
        countries=deserialize(joinpath(out,"countries.jls"))
        @test length(countries)==2
        @test countries[1].source.id!=countries[2].source.id
        @test countries[1].target.x==[0,2]
        @test deserialize(joinpath(out,"borders.jls"))==Set([(1,2)])
        edges=CE.graph(countries;borders=Set([(1,2)]))
        @test count(e->e[1]!=e[3],edges)==1
        fit=joinpath(root,"fit");mkpath(joinpath(fit,"fit"))
        plans=[CE.compact_solve(c,zeros(3,length(c.b)),nothing,CE.KA.CPU();eta=.002).plan for c in countries]
        CE.checkpoint(joinpath(fit,"fit","candidate.jls"),plans)
        write(joinpath(fit,"research-fit-complete.txt"),"test\n")
        mkpath(joinpath(original,"balanced","C"));write(joinpath(original,"balanced","C","preserved.txt"),"unchanged\n")
        extract_groups(original,out,fit)
        @test read(joinpath(out,"raw","C","preserved.txt"),String)=="unchanged\n"
        for group in ("A","B")
            mapping=CSV.read(joinpath(out,"raw",group,"mapping.csv"),DataFrame)
            @test all(startswith(id,group*":" ) for id in mapping.id)
            @test sum(mapping.weight)≈1
            @test all(mapping.weight_mean .≈ 1)
        end
        cp(joinpath(out,"raw"),joinpath(out,"balanced"))
        for group in ("A","B");cp(joinpath(out,"raw",group),joinpath(original,"balanced",group));end
        CE.checkpoint(joinpath(fit,"fit","baseline.jls"),plans)
        write(joinpath(out,"balance-complete.json"),"{}")
        @test_throws ErrorException audit_groups(original,out,fit)
        @test !JSON.parsefile(joinpath(out,"border-audit.json"))["numerical_gate"]
        @test_throws ErrorException prepare_groups(original,contacts,out;expected_tiles=6)
        @test_throws ErrorException prepare_groups(original,contacts,joinpath(root,"bad");expected_tiles=7)
    end
end
