using BugReporting, Test, Pkg, HTTP

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
        # Redirect `HOME` to a directory that we know doesn't contain a `.gdbinit` file,
        # as that can screw up the `isempty(rr_stderr)` test below
        withenv("HOME" => temporary_home) do
            old_stdout = Base.stdout
            old_stderr = Base.stderr
            old_stdin = Base.stdin

            new_stdout_rd, new_stdout_wr = Base.redirect_stdout()
            new_stderr_rd, new_stderr_wr = Base.redirect_stderr()
            new_stdin_rd, new_stdin_wr = Base.redirect_stdin()
            try
                # send in `continue` immediately to let it run
                write(new_stdin_wr, "continue\nquit\ny")
                BugReporting.replay(path)
            finally
                Base.redirect_stdout(old_stdout)
                Base.redirect_stderr(old_stderr)
                Base.redirect_stdin(old_stdin)
                close(new_stdout_wr)
                close(new_stderr_wr)
                close(new_stdin_rd)
            end

            rr_stdout = String(read(new_stdout_rd))
            rr_stderr = String(read(new_stderr_rd))

            if !isempty(rr_stderr)
                @warn """There were warnings during replay:
                            $rr_stderr"""
            end

            # Test that Julia spat out what we expect, still.
            @test occursin(msg, rr_stdout)
        end
    end

    # Test that we can create a replay
    mktempdir() do temp_trace_dir
        rr_stdout, rr_stderr = let
            old_stdout = Base.stdout
            old_stderr = Base.stderr

            new_stdout_rd, new_stdout_wr = Base.redirect_stdout()
            new_stderr_rd, new_stderr_wr = Base.redirect_stderr()
            proc = try
                BugReporting.rr_record(
                    Base.julia_cmd(),
                    "-e",
                    "println(\"$(msg)\")";
                    trace_dir=temp_trace_dir,
                )
            finally
                Base.redirect_stdout(old_stdout)
                Base.redirect_stderr(old_stderr)
                close(new_stdout_wr)
                close(new_stderr_wr)
            end
            @test success(proc)

            String(read(new_stdout_rd)), String(read(new_stderr_rd))
        end

        # Test that Julia spat out what we expect, and nothing was on stderr
        @test occursin(msg, rr_stdout)
        @test isempty(rr_stderr)

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
                HTTP.closewrite(http)
            end
            test_replay("http://127.0.0.1:$port")
            close(server)
        end
    end

    # Test that the --bug-report mode works
    mktempdir() do temp_trace_dir
        rr_stdout, rr_stderr = withenv("_RR_TRACE_DIR" => temp_trace_dir) do
            old_stdout = Base.stdout
            old_stderr = Base.stderr

            new_stdout_rd, new_stdout_wr = Base.redirect_stdout()
            new_stderr_rd, new_stderr_wr = Base.redirect_stderr()
            try
                run(```$(Base.julia_cmd()) --project=$(dirname(@__DIR__))
                                           --bug-report=rr-local
                                           --eval "println(\"$(msg)\")"```)
            finally
                Base.redirect_stdout(old_stdout)
                Base.redirect_stderr(old_stderr)
                close(new_stdout_wr)
                close(new_stderr_wr)
            end

            String(read(new_stdout_rd)), String(read(new_stderr_rd))
        end

        # Test that Julia spat out what we expect on stdout and stderr
        @test occursin(msg, rr_stdout)
        stderr_lines = split(rr_stderr, "\n")
        filter!(stderr_lines) do line
            !contains(line, "Loading BugReporting package...") && !isempty(line)
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
end
