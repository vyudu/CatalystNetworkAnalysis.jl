using CatalystNetworkAnalysis
using SafeTestsets, Test

@testset "CatalystNetworkAnalysis.jl" begin
    # Write your tests here.

    @time @safetestset "Concordance Helpers" begin include("concordancehelpers.jl") end
    @time @safetestset "Siphons" begin include("siphons.jl") end
    @time @safetestset "Persistence" begin include("persistence.jl") end
    @time @safetestset "Deficiency One Algorithm" begin include("deficiencyonealgorithm.jl") end
    @time @safetestset "Muliple Equilibria" begin include("multipleequilibria.jl")
end
