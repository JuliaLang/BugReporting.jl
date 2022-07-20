module BugReporting

# Use README as the docstring of the module:
@doc read(joinpath(dirname(@__DIR__), "README.md"), String) BugReporting

export replay, make_interactive_report

using Base.Filesystem: uperm
using rr_jll
using GDB_jll
using Zstd_jll
using HTTP, JSON
using AWS, AWSS3
using Tar
using Pkg

# https://github.com/JuliaLang/julia/pull/29411
if isdefined(Base, :exit_on_sigint)
    using Base: exit_on_sigint
else
    exit_on_sigint(on::Bool) =
        ccall(:jl_exit_on_sigint, Cvoid, (Cint,), on)
end

const WSS_ENDPOINT = "wss://53ly7yebjg.execute-api.us-east-1.amazonaws.com/test"
const GITHUB_APP_ID = "Iv1.c29a629771fe63c4"
const TRACE_BUCKET = "julialang-dumps"

function check_rr_available()
    if !isdefined(rr_jll, :rr_path)
        error("RR not available on this platform")
    end
end

# Values that are initialized in `__init__()`
global_record_flags = String[]
ignore_child_status = false

struct InvalidPerfEventParanoidError <: Exception
    value
end

function Base.showerror(io::IO, err::InvalidPerfEventParanoidError)
    println(io, "InvalidPerfEventParanoidError")
    print(io, """
    rr needs /proc/sys/kernel/perf_event_paranoid <= 1, but it is $(err.value).
    Change it to 1, or use `JULIA_RR_RECORD_ARGS=-n julia --bug-report=rr` (slow).
    Consider putting 'kernel.perf_event_paranoid = 1' in /etc/sysctl.conf
    or change it temporarily by
        echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid
    """)
end

# `path` used for testing
function check_perf_event_paranoid(path = "/proc/sys/kernel/perf_event_paranoid"; record_flags = global_record_flags)
    isempty(intersect(["-n", "--no-syscall-buffer"], record_flags)) || return
    isfile(path) || return  # let `rr` handle this
    value = tryparse(Int, read(path, String))
    value === nothing && return  # let `rr` handle this
    value <= 1 && return
    throw(InvalidPerfEventParanoidError(value))
end

function collect_inner_traces(trace_directory)
    # If this is already a trace directory, return just it
    if isfile(joinpath(trace_directory, "version"))
        return [trace_directory]
    end
    # If this is a directory containing traces, return those
    traces = String[]
    for f in readdir(trace_directory, join=true)
        if isfile(joinpath(f, "version"))
            push!(traces, f)
        end
    end
    return unique(realpath.(traces))
end

function find_latest_trace(trace_directory)
    # What _RR_TRACE_DIR calls a "trace directory" is not what `rr pack` calls a "trace directory"
    # This function allows us to normalize to the inner "latest-trace" directory, if necessary.
    latest_symlink = joinpath(trace_directory, "latest-trace")
    if !isfile(joinpath(trace_directory, "version")) && islink(latest_symlink)
        return realpath(latest_symlink)
    end
    return trace_directory
end

function rr_pack(trace_directory)
    check_rr_available()

    rr() do rr_path
        for dir in collect_inner_traces(trace_directory)
            @debug("rr pack'ing $(dir)")
            output = read(`$rr_path pack $(dir)`, String)
            isempty(output) || print(output)
        end
    end
end

# Helper function to compress a trace into a `.tar.zst` file
function compress_trace(trace_directory::String, output_file::String)
    # Ensure it's packed
    rr_pack(trace_directory)

    # Start up our `zstdmt` process to write out to that file
    proc = zstdmt() do zstdp
        open(pipeline(`$(zstdp) --quiet - -o $(output_file)`, stderr=stderr), "r+")
    end

    # Feed the tarball into that waiting process
    Tar.create(trace_directory, proc)

    # Ensure everything closes nicely
    close(proc.in)
    wait(proc)
    return nothing
end

function rr_record(args...; trace_dir=nothing)
    check_rr_available()
    check_perf_event_paranoid()

    rr() do rr_path
        new_env = copy(ENV)
        if trace_dir !== nothing
            new_env["_RR_TRACE_DIR"] = trace_dir
        end
        # Intersperse all given arguments with spaces, then splat:
        rr_cmd = `$(rr_path) record $(global_record_flags)`
        for arg in args
            rr_cmd = `$(rr_cmd) $(arg)`
        end
        return run(ignorestatus(setenv(rr_cmd, new_env)))
    end
end

function decompress_rr_trace(trace_file, out_dir)
    proc = zstdmt() do zstdp
        open(`$zstdp --quiet --stdout -d $trace_file`, "r+")
    end
    Tar.extract(proc, out_dir)
    return nothing
end

function decompress_rr_trace(trace_file)
    artifact_hash = Pkg.create_artifact() do dir
        decompress_rr_trace(trace_file, dir)
    end
    return Pkg.artifact_path(artifact_hash)
end

function download_rr_trace(trace_url; verbose=true)
    isdefined(Pkg.PlatformEngines, :probe_platform_engines) && Pkg.PlatformEngines.probe_platform_engines!()
    mktempdir() do dl_dir
        # Download into temporary directory, unpack into artifact directory
        local_path = joinpath(dl_dir, "trace.tar.zst")
        Pkg.PlatformEngines.download(trace_url, local_path; verbose=verbose)
        decompress_rr_trace(local_path)
    end
end

function replay(trace_url)
    if startswith(trace_url, "s3://")
        trace_url = string("https://s3.amazonaws.com/julialang-dumps/", trace_url[6:end])
    end
    if startswith(trace_url, "http://") || startswith(trace_url, "https://")
        trace_url = download_rr_trace(trace_url)
    end

    # If it's a file, try to decompress it
    if isfile(trace_url)
        trace_url = decompress_rr_trace(trace_url)
    end

    # If it's not a directory by now, we don't know what to do
    if !isdir(trace_url)
        error("Invalid trace location: $(trace_url)")
    end

    rr() do rr_path
        gdb() do gdb_path
            run(`$(rr_path) replay -d $(gdb_path) $(find_latest_trace(trace_url))`)
        end
    end
end

function handle_child_error(p::Base.Process)
    # If the user has requested that we ignore child status, do so
    if ignore_child_status
        return
    end

    if !success(p)
        println("""The debugged process failed. This is to be expected: Unless you see rr errors above,
                   the trace likely completed. Returning this status (code $(p.exitcode), signal $(p.termsignal)) to the caller.
                   If you want Julia to proceed instead, launch with JULIA_RR_IGNORE_STATUS=true.""")

        # Return the exit code if that is nonzero
        if p.exitcode != 0
            exit(p.exitcode)
        end

        # If the child instead signalled, we recreate the same signal in ourselves
        ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), p.termsignal, C_NULL)
        ccall(:raise, Cint, (Cint,), p.termsignal)
    end
end


function make_interactive_report(report_type, ARGS=[])
    default_julia_args = `--history-file=no`
    if report_type == "rr-local"
        proc = rr_record(`$(Base.julia_cmd()) $default_julia_args`, ARGS)
        handle_child_error(proc)
        return
    elseif report_type == "rr"
        exit_on_sigint(false)  # throw InterruptException on Ctrl-C
        local proc
        artifact_hash = Pkg.create_artifact() do trace_dir
            proc = rr_record(`$(Base.julia_cmd()) $default_julia_args`, ARGS; trace_dir=trace_dir)
            @info "Preparing trace directory for upload (if your trace is large this may take a few minutes)"
            rr_pack(trace_dir)
        end
        upload_rr_trace(Pkg.artifact_path(artifact_hash))
        handle_child_error(proc)
        return
    elseif report_type == "help"
        show(stdout, "text/plain", @doc(BugReporting))
        println()
        return
    end
    error("Unknown report type: $report_type")
end

const S3_CHUNK_SIZE = 25 * 1024 * 1024 # 25 MB

include("sync_compat.jl")

function upload_rr_trace(trace_directory)
    # Auto-pack this trace directory if it hasn't already been:
    sample_directory = joinpath(trace_directory, "latest-trace")
    if isdir(sample_directory) && uperm(sample_directory) & 0x2 == 0
        @info "`$sample_directory` not writable. Skipping `rr pack`."
    else
        rr_pack(trace_directory)
    end

    c = Channel()
    t = @async HTTP.WebSockets.open(WSS_ENDPOINT) do ws
        write(ws, "Hello Server, if it's not too much trouble, please send me S3 credentials")
        x = readavailable(ws)
        put!(c, JSON.parse(String(x))["connectionId"])
        # This will block until the user has completed the authentication flow
        x = readavailable(ws)
        push!(c, JSON.parse(String(x)))
    end
    bind(c, t)
    connectionId = take!(c)
    println()
    println("""
    ### IMPORTANT =============================================================
    You are about to upload a trace directory to a publicly accessible location.
    Such traces contain any information that was accessed by the traced
    executable during its execution. This includes any code loaded, any
    secrets entered, the contents of any configuration files, etc.
    DO NOT proceed, if you do not wish to make this information publicly available.
    By proceeding you explicitly agree to waive any privacy interest in the
    uploaded information.
    ### =======================================================================
    """)
    println("To upload a trace, please authenticate, by visiting:\n")
    println("\thttps://github.com/login/oauth/authorize?client_id=$GITHUB_APP_ID&state=$(HTTP.escapeuri(connectionId))")
    println("\n", "You can cancel upload by `Ctrl-C`.")
    flush(stdout)
    s3creds = try
        take!(c)
    catch err
        if err isa InterruptException
            println()
            println("Cancel uploading the trace.")
            return
        end
        rethrow()
    end

    println()
    @info "Uploading Trace directory"

    creds = AWS.AWSCredentials(
        s3creds["AWS_ACCESS_KEY_ID"],
        s3creds["AWS_SECRET_ACCESS_KEY"],
        s3creds["AWS_SESSION_TOKEN"])
    aws = AWS.AWSConfig(creds = creds, region="us-east-1")

    # Tar it up
    proc = zstdmt() do zstdp
        open(`$zstdp -`, "r+")
    end

    t = @async begin try
        upload = s3_begin_multipart_upload(aws, TRACE_BUCKET, s3creds["UPLOAD_PATH"])
        tags = Vector{String}()
        i = 1
        @Base.Experimental.sync begin
            while isopen(proc)
                buf = Vector{UInt8}(undef, S3_CHUNK_SIZE)
                n = readbytes!(proc, buf)
                n < S3_CHUNK_SIZE && resize!(buf, n)
                resize!(tags, i)
                let partno = i, buf=buf
                    @async begin
                        try
                            tags[partno] = s3_upload_part(aws, upload, partno, buf)
                        catch e
                            close(proc)
                            rethrow(e)
                        end
                    end
                end
                i += 1
            end
        end
        s3_complete_multipart_upload(aws, upload, tags)
    catch e
        Base.showerror(stderr, e)
    end
    end

    # Start the Tar creation process, the file will be uploaded as it's created
    Tar.create(trace_directory, proc)
    close(proc.in)

    wait(t)
    println("Uploaded to https://s3.amazonaws.com/$TRACE_BUCKET/$(s3creds["UPLOAD_PATH"])")
end


function __init__()
    # Read in environment variable settings
    global global_record_flags = split(get(ENV, "JULIA_RR_RECORD_ARGS", ""), ' ', keepempty=false)
    global ignore_child_status = parse(Bool, get(ENV, "JULIA_RR_IGNORE_STATUS", "false"))
end


end # module
