using Test, BugReporting

@testset "BugReporting" begin

include("go_compile.jl")
include("rr.jl")
include("unittests.jl")

end
