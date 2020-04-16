module BugReporting

using rr_jll
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

function do_pack(rr, trace_directory)
    @info "Preparing trace directory for upload (if your trace is large this may take a few minutes)"
    run(`$rr pack $trace_directory`)
end

function rr_record(rr)
    record_flags = split(get(ENV, "JULIA_RR_RECORD_ARGS", ""), ' ', keepempty=false)
    `$rr record $(record_flags)`
end

function make_interactive_report(report_type, ARGS=[])
    if report_type == "justrr"
        check_rr_available()
        rr() do rr
            run(`$(rr_record(rr)) $(Base.julia_cmd()) $ARGS`)
        end
        return
    elseif report_type == "rr"
        check_rr_available()
        artifact_hash = Pkg.create_artifact() do trace_directory
            rr() do rr
                # Record
                new_env = copy(ENV)
                new_env["_RR_TRACE_DIR"] = trace_directory
                run(setenv(`$(rr_record(rr)) $(Base.julia_cmd()) $ARGS`, new_env))
                # Pack
                do_pack(rr, "$trace_directory/latest-trace")
            end
        end
        upload_rr_trace(Pkg.artifact_path(artifact_hash); pack=false)
        return
    end
    error("Unknown report type")
end

const S3_CHUNK_SIZE = 25 * 1024 * 1024 # 25 MB

include("sync_compat.jl")

function upload_rr_trace(trace_directory; pack=true)
    if pack
        rr() do rr
            do_pack(rr, trace_directory)
        end
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
    println("\thttps://github.com/login/oauth/authorize?client_id=$GITHUB_APP_ID&state=$connectionId")
    s3creds = take!(c)

    println()
    @info "Uploading Trace directory"

    creds = AWSCore.AWSCredentials(
        s3creds["AWS_ACCESS_KEY_ID"],
        s3creds["AWS_SECRET_ACCESS_KEY"],
        s3creds["AWS_SESSION_TOKEN"])
    aws = AWSCore.aws_config(creds = creds, region="us-east-1")

    # Tar it up
    proc = open(`gzip -`, "r+")

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
    println("Uploaded to s3://$TRACE_BUCKET/$(s3creds["UPLOAD_PATH"])")
end

end # module
