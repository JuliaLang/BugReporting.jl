module BugReporting

export replay, make_interactive_report

using rr_jll
using Zstd_jll
using HTTP, JSON
using AWSCore, AWSS3
using Tar
using Pkg

const WSS_ENDPOINT = "wss://53ly7yebjg.execute-api.us-east-1.amazonaws.com/test"
const GITHUB_APP_ID = "Iv1.c29a629771fe63c4"
const TRACE_BUCKET = "julialang-dumps"

function check_rr_available()
    if isempty(rr_jll.rr_path)
        error("RR not available on this platform")
    end
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
            run(`$rr_path pack $(dir)`)
        end
    end
end

function rr_record(args...; trace_dir=nothing)
    check_rr_available()

    record_flags = split(get(ENV, "JULIA_RR_RECORD_ARGS", ""), ' ', keepempty=false)
    rr() do rr_path
        new_env = copy(ENV)
        if trace_dir !== nothing
            new_env["_RR_TRACE_DIR"] = trace_dir
        end
        # Intersperse all given arguments with spaces, then splat:
        rr_cmd = `$(rr_path) record $(record_flags)`
        for arg in args
            rr_cmd = `$(rr_cmd) $(arg)`
        end
        run(ignorestatus(setenv(rr_cmd, new_env)))
    end
end

function download_rr_trace(trace_url; verbose=true)
    Pkg.PlatformEngines.probe_platform_engines!()
    artifact_hash = Pkg.create_artifact() do dir
        mktempdir() do dl_dir
            # Download into temporary directory, unpack into artifact directory
            local_path = joinpath(dl_dir, "trace.tar.zst")
            Pkg.PlatformEngines.download(trace_url, local_path; verbose=verbose)
            proc = zstdmt() do zstdp
                open(`$zstdp --stdout -d $local_path`, "r+")
            end
            Tar.extract(proc, dir)
        end
    end
    return Pkg.artifact_path(artifact_hash)
end

function replay(trace_url)
    if startswith(trace_url, "s3://")
        trace_url = string("https://s3.amazonaws.com/julialang-dumps/", trace_url[6:end])
    end
    if startswith(trace_url, "https://")
        trace_url = download_rr_trace(trace_url)
    end

    if !isdir(trace_url)
        error("Invalid trace location: $(trace_url)")
    end

    rr() do rr_path
        run(`$(rr_path) replay $(find_latest_trace(trace_url))`)
    end
end


function make_interactive_report(report_type, ARGS=[])
    if report_type == "justrr"
        rr_record(Base.julia_cmd(), ARGS)
        return
    elseif report_type == "rr"
        artifact_hash = Pkg.create_artifact() do trace_dir
            rr_record(Base.julia_cmd(), ARGS; trace_dir=trace_dir)
            @info "Preparing trace directory for upload (if your trace is large this may take a few minutes)"
            rr_pack(trace_dir)
        end
        upload_rr_trace(Pkg.artifact_path(artifact_hash))
        return
    end
    error("Unknown report type")
end

const S3_CHUNK_SIZE = 25 * 1024 * 1024 # 25 MB

include("sync_compat.jl")

function upload_rr_trace(trace_directory)
    # Auto-pack this trace directory if it hasn't already been:
    rr_pack(trace_directory)

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
    s3creds = take!(c)

    println()
    @info "Uploading Trace directory"

    creds = AWSCore.AWSCredentials(
        s3creds["AWS_ACCESS_KEY_ID"],
        s3creds["AWS_SECRET_ACCESS_KEY"],
        s3creds["AWS_SESSION_TOKEN"])
    aws = AWSCore.aws_config(creds = creds, region="us-east-1")

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
                let partno = i, buf=buf
                    @async begin
                        try
                            push!(tags, s3_upload_part(aws, upload, partno, buf))
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

end # module
