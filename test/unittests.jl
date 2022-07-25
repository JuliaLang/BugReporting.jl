module BugReportingUnitTests

using BugReporting:
    check_perf_event_paranoid, InvalidPerfEventParanoidError
using Test

@testset "check_perf_event_paranoid" begin
    function check(value, rr_flags=``)
        mktemp() do path, io
            write(io, value)
            close(io)
            check_perf_event_paranoid(path; rr_flags=rr_flags)
        end
        return true
    end
    @test check("0")
    @test check("1")
    @test_throws InvalidPerfEventParanoidError check("2")
    @test_throws InvalidPerfEventParanoidError check("3")
    @test check("2", `-n`)
    @test check("2", `--no-syscall-buffer`)

    # Let `rr` handle these?
    @test check("non integer")
    @test check_perf_event_paranoid("/hopefully/non/existing/path"; rr_flags=``) === nothing

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
