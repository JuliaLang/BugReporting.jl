module BugReporting

using Scratch

# Use README as the docstring of the module:
@doc read(joinpath(dirname(@__DIR__), "README.md"), String) BugReporting

export replay, make_interactive_report

using Base.Filesystem: uperm
using rr_jll
using GDB_jll
using Zstd_jll
using Elfutils_jll
using HTTP, JSON
using AWS, AWSS3
using Tar
using Git
import Downloads

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
const METADATA_VERSION = v"1"

function check_rr_available()
    if !isdefined(rr_jll, :rr_path)
        error("RR not available on this platform")
    end
end

# Values that are initialized in `__init__()`
default_rr_record_flags = ``
julia_checkout = ""

struct InvalidPerfEventParanoidError <: Exception
    value
end

function Base.showerror(io::IO, err::InvalidPerfEventParanoidError)
    println(io, "InvalidPerfEventParanoidError")
    print(io, """
        rr needs /proc/sys/kernel/perf_event_paranoid <= 1, but it is $(err.value).
        Change it to 1, or use `JULIA_RR_RECORD_ARGS=-n julia --bug-report=rr` (slow).
        Consider putting 'kernel.perf_event_paranoid = 1' in /etc/sysctl.conf
        and rebooting. You can change the value for the current session by executing
            echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid
        """)
end

# `path` used for testing
function check_perf_event_paranoid(path="/proc/sys/kernel/perf_event_paranoid"; rr_flags=``)
    isempty(intersect(["-n", "--no-syscall-buffer"], rr_flags.exec)) || return
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

function rr_record(julia_cmd::Cmd, julia_args...; rr_flags=default_rr_record_flags,
                   trace_dir=nothing, metadata=nothing, timeout=0)
    check_rr_available()
    check_perf_event_paranoid(; rr_flags=rr_flags)

    new_env = copy(ENV)
    if trace_dir !== nothing
        new_env["_RR_TRACE_DIR"] = trace_dir
    elseif haskey(ENV, "_RR_TRACE_DIR")
        trace_dir = ENV["_RR_TRACE_DIR"]
    else
        # find the trace dir just like rr does (see `default_rr_trace_dir`)
        # TODO: get the trace dir by passing --print-trace-dir to `rr record`
        #       (this requires passing a fd, which isn't straightforward in Julia)
        dot_dir = joinpath(homedir(), ".rr")
        xdg_dir = if haskey(ENV, "XDG_DATA_HOME")
            joinpath(ENV["XDG_DATA_HOME"], "rr")
        else
            joinpath(homedir(), ".local", "share", "rr")
        end
        trace_dir = if !isdir(xdg_dir) && isdir(dot_dir)
            # backwards compatibility
            dot_dir
        else
            xdg_dir
        end
    end

    # loading GDB_jll sets PYTHONHOME via Python_jll. this only matters for replay,
    # and shouldn't leak into the Julia environment (which may load its own Python)
    delete!(new_env, "PYTHONHOME")

    proc = rr() do rr_path
        rr_cmd = `$(rr_path) record $rr_flags $julia_cmd $(julia_args...)`
        cmd = ignorestatus(setenv(rr_cmd, new_env))

        proc = run(cmd, stdin, stdout, stderr; wait=false)

        exit_on_sigint(false)
        @sync begin
            t1 = @async while process_running(proc)
                try
                    wait(proc)
                catch err
                    isa(err, InterruptException) || throw(err)
                    println("Interrupting the process...")
                    kill(proc, Base.SIGINT)
                    Timer(2) do timer
                        process_running(proc) || return
                        println("Terminating the process...")
                        kill(proc, Base.SIGTERM)
                    end
                    Timer(5) do timer
                        process_running(proc) || return
                        println("Killing the process...")
                        kill(proc, Base.SIGKILL)
                    end
                end
            end

            if timeout > 0
                @async Timer(2) do timer
                    istaskdone(t1) || Base.throwto(t1, InterruptException())
                end
            end
        end
        return proc
    end

    # add metadata to the trace
    if metadata !== nothing
        open(joinpath(find_latest_trace(trace_dir), "julia_metadata.json"), "w") do io
            JSON.print(io, metadata)
        end
    end

    return proc
end

function decompress_rr_trace(trace_file, out_dir)
    proc = zstdmt() do zstdp
        open(`$zstdp --quiet --stdout -d $trace_file`, "r+")
    end
    Tar.extract(proc, out_dir)
    return nothing
end

function decompress_rr_trace(trace_file)
    # Extract into temporary directory (we'll clean-up when the process exists)
    dir = mktempdir()
    decompress_rr_trace(trace_file, dir)
    return dir
end

function download_rr_trace(trace_url)
    mktempdir() do dl_dir
        # Download into temporary directory (we'll clean-up straight away)
        local_path = joinpath(dl_dir, "trace.tar.zst")
        Downloads.download(trace_url, local_path)
        decompress_rr_trace(local_path)
    end
end

function get_sourcecode(commit)
    # core check-out
    if ispath(joinpath(julia_checkout, "config"))
        run(`$(git()) -C $julia_checkout fetch --quiet`)
    else
        println("Checking-out Julia source code, this may take a minute...")
        run(`$(git()) clone --quiet --bare https://github.com/JuliaLang/julia.git $julia_checkout`)
    end

    # verify commit
    cmd = `$(git()) -C $julia_checkout rev-parse --quiet --verify $commit`
    success(pipeline(cmd, stdout=devnull)) || return nothing

    # check-out source code
    dir = mktempdir()
    run(`$(git()) clone --quiet $julia_checkout $dir`)
    run(`$(git()) -C $dir checkout --quiet $commit`)
    return dir
end

function replay(trace_url; gdb_commands=[], gdb_flags=``)
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
    trace_dir = find_latest_trace(trace_url)

    # read Julia-specific metadata from the trace
    if ispath(joinpath(trace_dir, "julia_metadata.json"))
        metadata = JSON.parsefile(joinpath(trace_dir, "julia_metadata.json"))

        # check metadata semver
        metadata_version = VersionNumber(metadata["version"])
        if metadata_version >= v"2"
            metadata = nothing
        end
    else
        metadata = nothing
    end

    gdb_args = `$gdb_flags`
    if metadata !== nothing
        source_code = get_sourcecode(metadata["commit"])
        if source_code !== nothing
            if haskey(metadata, "comp_dir")
                gdb_args = `$gdb_args -ex "set substitute-path $(metadata["comp_dir"]) $source_code"`
            else
                gdb_args = `$gdb_args -ex "directory $(joinpath(source_code, "src"))"`
                gdb_args = `$gdb_args -ex "directory $(joinpath(source_code, "base"))"`
            end
        else
            @warn "Could not find the source code for Julia commit $commit."
        end
    end
    for gdb_command in gdb_commands
        gdb_args = `$gdb_args -ex "$gdb_command"`
    end

    proc = rr() do rr_path
        gdb() do gdb_path
            run(`$(rr_path) replay -d $(gdb_path) $trace_dir -- $gdb_args`)
        end
    end

    if @isdefined(source_code) && source_code !== nothing
        rm(source_code; recursive=true)
    end

    return proc
end

function handle_child_error(p::Base.Process)
    # if the parent process is interactive, we shouldn't exit if the child process failed.
    if isinteractive()
        return
    end

    # for non-interactive sessions, likely from `--bug-report`, we want to propagate failure
    if !success(p)
        # Return the exit code if that is nonzero
        if p.exitcode != 0
            exit(p.exitcode)
        end

        # If the child instead signalled, we recreate the same signal in ourselves
        ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), p.termsignal, C_NULL)
        ccall(:raise, Cint, (Cint,), p.termsignal)
    end
end

function read_comp_dir(binary_path)
    # TODO: use libelf instead of grepping the human-readable output of readelf
    elf_dump = eu_readelf() do eu_readelf_path
        read(`$eu_readelf_path --debug-dump=info $binary_path`, String)
    end

    current_comp_dir = nothing
    for line in split(elf_dump, '\n')
        # scan for DW_AT_comp_dir tags...
        let m = match(r"comp_dir.+\"(.+)\"", line)
            if m !== nothing
                current_comp_dir = m.captures[1]
                continue
            end
        end

        # ... return the one where DW_AT_name==main
        let m = match(r"name.+\"main\"", line)
            if m !== nothing
                if current_comp_dir !== nothing
                    return dirname(current_comp_dir)
                end
            end
        end
    end

    return
end

function make_interactive_report(report_arg, ARGS=[])
    if report_arg == "help"
        show(stdout, "text/plain", @doc(BugReporting))
        println()
        return
    end

    # split the report specification into the type and any modifiers
    report_type, report_modifiers... = split(report_arg, ',')
    timeout = 0
    for report_modifier in report_modifiers
        option, value = split(report_modifier, '=')
        if option == "timeout"
            timeout = parse(Int, value)
        else
            error("Unknown report option: $(option)")
        end
    end

    # construct the Julia command
    cmd = Base.julia_cmd()
    if Base.JLOptions().project != C_NULL
        # --project is not included in julia_cmd
        cmd = `$cmd --project=$(unsafe_string(Base.JLOptions().project))`
    end
    if Base.JLOptions().commands != C_NULL
        # -e and friends aren't either
        commands = Dict(Base.unsafe_load_commands(Base.JLOptions().commands))
        if haskey(commands, 'e')
            cmd = `$cmd -e $(commands['e'])`
        end
    end
    cmd = `$cmd --history-file=no`

    # we know that the currently executing Julia process matches the one we'll be recording,
    # so gather some additional information and add it as metadata to the trace
    metadata = Dict(
        "version"   => string(METADATA_VERSION),
        "commit"    => Base.GIT_VERSION_INFO.commit
    )
    # TODO: use `-fdebug-prefix-map` during the build instead
    comp_dir = read_comp_dir(Base.julia_cmd().exec[1])
    if comp_dir !== nothing
        metadata["comp_dir"] = comp_dir
    else
        @error "Could not find the compilation directory, source paths may be incorrect during replay. Please file an issue on the BugReporting.jl repository."
    end

    if report_type == "rr-local"
        proc = rr_record(cmd, ARGS...; metadata=metadata, timeout=timeout)
        handle_child_error(proc)
        return
    elseif report_type == "rr"
        proc = mktempdir() do trace_dir
            proc = rr_record(cmd, ARGS...; trace_dir=trace_dir, metadata=metadata,
                                           timeout=timeout)
            @info "Preparing trace directory for upload (if your trace is large this may take a few minutes)"
            rr_pack(trace_dir)
            upload_rr_trace(trace_dir)
            proc
        end
        handle_child_error(proc)
        return
    else
        error("Unknown report type: $report_type")
    end
end

const S3_CHUNK_SIZE = 25 # MB

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
        HTTP.send(ws, "Hello Server, if it's not too much trouble, please send me S3 credentials")

        let resp = HTTP.receive(ws)
            isa(resp, String) || error("Invalid response from authentication server: expected TEXT, got BINARY")
            data = try
                JSON.parse(String(resp))
            catch
                error("Invalid response from authentication server: could not parse JSON reply (got '$resp')")
            end
            if !isa(data, Dict) || !haskey(data, "connectionId")
                error("Invalid response from authentication server: invalid JSON reply (expected connectionId dict, got '$resp')")
            end
            put!(c, data["connectionId"])
        end

        # This will block until the user has completed the authentication flow
        let resp = HTTP.receive(ws)
            isa(resp, String) || error("Invalid response from authentication server: expected TEXT, got BINARY")
            data = try
                JSON.parse(String(resp))
            catch
                error("Invalid response from authentication server: could not parse JSON reply (got '$resp')")
            end
            if !isa(data, Dict) || !haskey(data, "AWS_ACCESS_KEY_ID") || !haskey(data, "UPLOAD_PATH") ||
               !haskey(data, "AWS_SECRET_ACCESS_KEY") || !haskey(data, "AWS_SESSION_TOKEN")
                error("Invalid response from authentication server: invalid JSON reply (expected connectionId dict, got '$resp')")
            end
            isa(resp, String) || error("Invalid response from authentication server: expected TEXT, got BINARY")
            push!(c, data)
        end
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
            println("Canceled uploading the trace.")
            return
        end
        rethrow()
    end

    println()
    println("Uploading trace directory...")

    creds = AWS.AWSCredentials(
        s3creds["AWS_ACCESS_KEY_ID"],
        s3creds["AWS_SECRET_ACCESS_KEY"],
        s3creds["AWS_SESSION_TOKEN"])
    aws = AWS.AWSConfig(creds = creds, region="us-east-1")

    # Tar it up
    proc = zstdmt() do zstdp
        open(`$zstdp -`, "r+")
    end

    t = @async begin
        try
            s3_multipart_upload(aws, TRACE_BUCKET, s3creds["UPLOAD_PATH"], proc, S3_CHUNK_SIZE)
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
    if haskey(ENV, "JULIA_RR_RECORD_ARGS")
        global default_rr_record_flags = eval(:(@cmd($(ENV["JULIA_RR_RECORD_ARGS"]))))
    end

    global julia_checkout = @get_scratch!("julia")
end


end # module
