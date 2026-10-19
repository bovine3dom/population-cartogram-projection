@testset "Typed sparse balance kernel" begin
    O=OWIDLayout
    # Compare with a dense reference on full positive support.
    matrix=[1. 3.;2. 4.];supply=[10.,30.];expected=copy(matrix)
    for _ in 1:100
        expected .*= 20 ./ sum(expected;dims=1)
        expected .*= supply ./ vec(sum(expected;dims=2))
    end
    rows=[1,1,2,2];cols=[1,2,1,2];mass=[1.,3.,2.,4.]
    result=@inferred O.balance_kernel!(mass,rows,cols,supply,2;iterations=1000,tolerance=1e-10)
    @test result.converged
    @test mass≈[expected[1,1],expected[1,2],expected[2,1],expected[2,2]] rtol=1e-9
    @test result.error<=1e-10
    @test result.target_mass≈[20.,20.]
    # Infeasible support runs every iteration. Allocations must not grow with
    # the iteration count. A wall-clock threshold would depend on the host.
    diagonal=[1,2];population=[1.,3.];weights=copy(population)
    O.balance_kernel!(weights,diagonal,diagonal,population,2;iterations=10,tolerance=1e-4)
    short=@allocated O.balance_kernel!(weights,diagonal,diagonal,population,2;iterations=10,tolerance=1e-4)
    long=@allocated O.balance_kernel!(weights,diagonal,diagonal,population,2;iterations=1000,tolerance=1e-4)
    @test long<=short+1024
    failed=O.balance_kernel!(weights,diagonal,diagonal,population,2;iterations=100,tolerance=1e-4)
    @test !failed.converged && failed.error==.5
    @test weights==population
end
