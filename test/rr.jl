using BugReporting, Test, Pkg, HTTP

@testset "rr" begin
    try
        BugReporting.check_rr_available()
    catch
        @info("Skipping `rr` tests, as `rr` unavailable on $(Pkg.BinaryPlatforms.platform_key_abi())")
        return
    end

    # Test that we can create a replay
    mktempdir() do temp_trace_dir
        msg = "Time is precious, spend it wisely"
        old_stdout = Base.stdout
        old_stderr = Base.stderr
        old_stdin = Base.stdin

        new_stdout_rd, new_stdout_wr = Base.redirect_stdout()
        new_stderr_rd, new_stderr_wr = Base.redirect_stderr()
        try
            BugReporting.rr_record(
                Base.julia_cmd(),
                "-e",
                "println(\"$(msg)\")";
                trace_dir=temp_trace_dir,
            )
        finally;
            Base.redirect_stdout(old_stdout)
            Base.redirect_stderr(old_stderr)
            close(new_stdout_wr)
            close(new_stderr_wr)
        end

        rr_stdout = String(read(new_stdout_rd))
        rr_stderr = String(read(new_stderr_rd))

        # Test that Julia spat out what we expect, and nothing was on stderr:
        @test occursin(msg, rr_stdout)
        @test isempty(rr_stderr)

        # Test that we get something put into the temp trace directory
        @test islink(joinpath(temp_trace_dir, "latest-trace"))

        # Test that we can pack the trace directory, and that it generates `mmap_pack` files
        BugReporting.rr_pack(temp_trace_dir)
        trace_files = readdir(joinpath(temp_trace_dir,"latest-trace"))
        @test !isempty(filter(f -> startswith(f, "mmap_pack_"), trace_files))

        # Test that we can replay that trace
        function test_replay(path)
            # Redirect `HOME` to a directory that we know doesn't contain a `.gdbinit` file,
            # as that can screw up the `isempty(rr_stderr)` test below
            withenv("HOME" => temp_trace_dir) do
                # send in `continue` immediately to let it run
                local new_stdout_wr, new_stderr_wr, new_stdin_rd
                try
                    new_stdout_rd, new_stdout_wr = Base.redirect_stdout()
                    new_stderr_rd, new_stderr_wr = Base.redirect_stderr()
                    new_stdin_rd, new_stdin_wr = Base.redirect_stdin()
                    write(new_stdin_wr, "continue\nquit\ny")
                    BugReporting.replay(path)
                catch
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
        test_replay(temp_trace_dir)

        # Test that we can compress that trace directory, and replay that
        mktempdir() do temp_out_dir
            tarzst_path = joinpath(temp_out_dir, "trace.tar.zst")
            BugReporting.compress_trace(temp_trace_dir, tarzst_path)
            @test isfile(tarzst_path)
            test_replay(tarzst_path)

            # Test that we can replay that trace from an URL (actually uploading it is hard)
            server = @async begin
                HTTP.listen("127.0.0.1", 8081) do http::HTTP.Stream
                    HTTP.setstatus(http, 200)
                    HTTP.startwrite(http)
                    write(http, read(tarzst_path))
                    HTTP.closewrite(http)
                end
            end
            sleep(1)
            test_replay("http://127.0.0.1:8081")
        end
    end
end
