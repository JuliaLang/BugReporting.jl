# Perhaps someday we'll have a `go_jll`. ;)
@testset "S3Vendor" begin
    @test isfile(joinpath(@__DIR__, "..", "S3Vendor_go", "main.go"))
    cd(joinpath(@__DIR__, "..", "S3Vendor_go")) do
        # Check to see if `go version` gives us something new enough:
        if Sys.which("go") === nothing
            @info("Skipping S3Vendor compile test due to lack of `go` compiler")
            return
        end

        gv = read(`go version`)
        m = match(r"^go version go([\d\.]+) ", String(read(`go version`)))
        if m === nothing
            @info("Skipping S3Vendor compile test due to inability to run `go version` check")
            return
        end

        if VersionNumber(m.captures[1]) < v"1.11"
            @info("Skipping S3Vendor compile test due to outdated `go` version ($(m.captures[1]) < 1.11)")
            return
        end

        run(`go build`)
        @test isfile("S3Vendor_go")
        rm("S3Vendor_go")
    end
end
