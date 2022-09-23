using Pkg, CloudBase.CloudTest

# helper functions to run a command or a block of code while capturing all output
function communicate(f::Function)
    old_stdout = Base.stdout
    old_stderr = Base.stderr

    new_stdout_rd, new_stdout_wr = Base.redirect_stdout()
    new_stderr_rd, new_stderr_wr = Base.redirect_stderr()
    rv = try
        f()
    finally
        Base.redirect_stdout(old_stdout)
        Base.redirect_stderr(old_stderr)
        close(new_stdout_wr)
        close(new_stderr_wr)
    end

    return rv, (
        stdout = String(read(new_stdout_rd)),
        stderr = String(read(new_stderr_rd))
    )
end
function communicate(cmd::Cmd)
    out = Pipe()
    err = Pipe()

    proc = run(pipeline(cmd, stdout=out, stderr=err), wait=false)
    close(out.in)
    close(err.in)

    stdout = @async String(read(out))
    stderr = @async String(read(err))
    wait(proc)
    return proc, (
        stdout = fetch(stdout),
        stderr = fetch(stderr)
    )
end

@testset "rr" begin
    try
        BugReporting.check_rr_available()
    catch
        @info("Skipping `rr` tests, as `rr` unavailable on $(Pkg.BinaryPlatforms.platform_key_abi())")
        return
    end

    msg = "Time is precious, spend it wisely"
    temporary_home = mktempdir()
    function test_replay(path)
        # send in `continue` immediately to let it run
        _, output = communicate() do
            BugReporting.replay(path; gdb_flags=`-nh -batch`, gdb_commands=["continue", "quit"])
        end

        if !isempty(output.stderr)
            @warn """There were warnings during replay:
                        $(output.stderr)"""
        end

        # Test that Julia spat out what we expect, still.
        @test occursin(msg, output.stdout)
    end

    # Test that we can create a replay
    mktempdir() do temp_trace_dir
        proc, output = communicate() do
            BugReporting.rr_record(
                Base.julia_cmd(),
                "-e",
                "println(\"$(msg)\")";
                trace_dir=temp_trace_dir,
            )
        end
        @test success(proc)

        # Test that Julia spat out what we expect, and nothing was on stderr
        @test occursin(msg, output.stdout)
        if !isempty(output.stderr)
            @error "Unexpected output on standard error:\n" * output.stderr
        end
        @test isempty(output.stderr)

        # Test that we get something put into the temp trace directory
        @test islink(joinpath(temp_trace_dir, "latest-trace"))

        # Test that we can pack the trace directory, and that it generates `mmap_pack` files
        BugReporting.rr_pack(temp_trace_dir)
        trace_files = readdir(joinpath(temp_trace_dir,"latest-trace"))
        @test !isempty(filter(f -> startswith(f, "mmap_pack_"), trace_files))

        # Test that we can replay that trace
        test_replay(temp_trace_dir)

        # Test that we can compress that trace directory, and replay that
        mktempdir() do temp_out_dir
            tarzst_path = joinpath(temp_out_dir, "trace.tar.zst")
            BugReporting.compress_trace(temp_trace_dir, tarzst_path)
            @test isfile(tarzst_path)
            test_replay(tarzst_path)
        end

        # Test that we can upload a trace directory, and replay it.
        # Note that Minio requires a non-tmpfs working directory,
        # so we don't use plain mktempdir() as /tmp is likely to be tmpfs.
        cache_dir = if haskey(ENV, "CI")
            # most of our Sandbox.jl-based environment is tmpfs-backed, but /cache isn't
            "/cache"
        else
            get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
        end
        mkpath(cache_dir)
        mktempdir(cache_dir) do temp_srv_dir
            Minio.with(; public=true, dir=temp_srv_dir) do conf
                creds, bucket = conf
                s3_url = "s3://$(bucket.name)/test.tar.zst"
                http_url = bucket.baseurl * "test.tar.zst"
                endpoint_url = replace(bucket.baseurl, "$(bucket.name)/"=>"")
                withenv("S3_ENDPOINT_URL" => endpoint_url) do
                    BugReporting.upload_rr_trace(temp_trace_dir, s3_url; creds.access_key_id,
                                                 creds.secret_access_key, creds.session_token)
                end

                test_replay(http_url)
            end
        end
    end

    # Test that the --bug-report mode works
    mktempdir() do temp_trace_dir
        proc, output = withenv("_RR_TRACE_DIR" => temp_trace_dir) do
            cmd = ```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                         --bug-report=rr-local
                                         --eval "println(\"$(msg)\")"```
            communicate(cmd)
        end
        @test success(proc)

        # Test that Julia spat out what we expect on stdout and stderr
        @test occursin(msg, output.stdout)
        stderr_lines = split(output.stderr, "\n")
        filter!(stderr_lines) do line
            !contains(line, "Loading BugReporting package...") && !isempty(line)
        end
        if !isempty(stderr_lines)
            @error "Unexpected output on standard error:\n" * output.stderr
        end
        @test isempty(stderr_lines)

        test_replay(temp_trace_dir)

        # Test that `--bug-report` propagates the child's exit status
        @test  success(```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                              --bug-report=rr-local
                                              --eval "exit(0)"```)
        @test !success(```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                              --bug-report=rr-local
                                              --eval "exit(1)"```)
    end

    # Test that Julia source code is made available for traces
    mktempdir() do temp_trace_dir
        proc, _ = withenv("_RR_TRACE_DIR" => temp_trace_dir) do
            cmd = ```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                         --bug-report=rr-local
                                         --eval "ccall(:jl_breakpoint, Cvoid, (Any,), 42)"```
            communicate(cmd)
        end
        @test success(proc)

        proc, output = communicate() do
            BugReporting.replay(temp_trace_dir; gdb_flags=`-nh -batch`, gdb_commands=[
                    "continue",
                    "break jl_breakpoint",
                    "reverse-continue",
                    "info source",
                    "quit"
                ])
        end
        @test success(proc)

        @test contains(output.stdout, r"Current source file is .+\.c")
        @test contains(output.stdout, "Located in")
        @test contains(output.stdout, r"Contains \d+ lines")
    end

    # Test that standard library source code is made available for traces
    mktempdir() do temp_trace_dir
        proc, _ = withenv("_RR_TRACE_DIR" => temp_trace_dir) do
            cmd = ```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                         --bug-report=rr-local
                                         --eval "Regex(\"\")"```
            communicate(cmd)
        end
        @test success(proc)

        proc, output = communicate() do
            BugReporting.replay(temp_trace_dir; gdb_flags=`-nh -batch`, gdb_commands=[
                    "continue",
                    "break pcre2_jit_compile_8",
                    "reverse-continue",
                    "up",
                    "info source",
                    "bt",
                    "quit"
                ])
        end
        @test success(proc)

        @test contains(output.stdout, r"Current source file is .+\.jl")
        @test contains(output.stdout, "Located in")
        @test contains(output.stdout, r"Contains \d+ lines")
    end

    # Test that we can set a timeout
    mktempdir() do temp_trace_dir
        t0 = time()
        proc, output = withenv("_RR_TRACE_DIR" => temp_trace_dir) do
            cmd = ```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                         --bug-report=rr-local,timeout=2
                                         --eval "println(\"Starting sleep\"); sleep(60)"```
            communicate(cmd)
        end
        @test !success(proc)
        t1 = time()
        @test t1-t0 < 30
        @test contains(output.stdout, "Starting sleep")

        # the recording should be valid, despite having been killed due to a timeout
        proc, output = communicate() do
            BugReporting.replay(temp_trace_dir; gdb_flags=`-nh -batch`, gdb_commands=[
                    "continue",
                    "quit"
                ])
        end
        @test success(proc)
        @test contains(output.stdout, "Starting sleep")
    end
end
