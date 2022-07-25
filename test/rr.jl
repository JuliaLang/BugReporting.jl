using BugReporting, Test, Pkg, HTTP

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

            # Test that we can replay that trace from an URL (actually uploading it is hard)
            port = rand(1024:65535)
            server = HTTP.listen!("127.0.0.1", port) do http::HTTP.Stream
                HTTP.setstatus(http, 200)
                HTTP.startwrite(http)
                write(http, read(tarzst_path))
            end
            test_replay("http://127.0.0.1:$port")
            close(server)
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

        @test contains(output.stdout, "Current source file is")
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
