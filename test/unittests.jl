module BugReportingUnitTests

using BugReporting:
    check_perf_event_paranoid, get_record_flags, InvalidPerfEventParanoidError
using Test

@testset "get_record_flags" begin
    @test withenv(get_record_flags, "JULIA_RR_RECORD_ARGS" => "") == String[]
    @test withenv(get_record_flags, "JULIA_RR_RECORD_ARGS" => " ") == String[]
    @test withenv(get_record_flags, "JULIA_RR_RECORD_ARGS" => "-n") == ["-n"]
    @test withenv(get_record_flags, "JULIA_RR_RECORD_ARGS" => " -n ") == ["-n"]
end

@testset "check_perf_event_paranoid" begin
    function check(value, flags = "")
        mktemp() do path, io
            write(io, value)
            close(io)
            withenv("JULIA_RR_RECORD_ARGS" => flags) do
                check_perf_event_paranoid(path)
            end
        end
        return true
    end
    @test check("0")
    @test check("1")
    @test_throws InvalidPerfEventParanoidError check("2")
    @test_throws InvalidPerfEventParanoidError check("3")
    @test check("2", "-n")
    @test check("2", "--no-syscall-buffer")

    # Let `rr` handle these?
    @test check("non integer")
    withenv("JULIA_RR_RECORD_ARGS" => "") do
        @test check_perf_event_paranoid("/hopefully/non/existing/path") === nothing
    end

    err = try
        check("2")
    catch err
        err
    end
    @test err isa InvalidPerfEventParanoidError
    msg = sprint(showerror, err)
    @test contains(msg, "rr needs /proc/sys/kernel/perf_event_paranoid <= 1, but it is 2")
end

end  # module
