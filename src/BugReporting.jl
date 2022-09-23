module BugReporting

using Scratch

# Use README as the docstring of the module:
@doc read(joinpath(dirname(@__DIR__), "README.md"), String) BugReporting

export replay, make_interactive_report

using Base.Filesystem: uperm
using rr_jll: rr_jll, rr
using GDB_jll: gdb
using Zstd_jll: zstdmt
using Elfutils_jll: eu_readelf
import HTTP
using JSON
import Tar
using Git: git
import Downloads
using ProgressMeter: Progress, update!
using s5cmd_jll: s5cmd

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
trace_cache = ""

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

# find the trace dir just like rr doesn
function default_rr_trace_dir()
    if haskey(ENV, "_RR_TRACE_DIR")
        ENV["_RR_TRACE_DIR"]
    else
        dot_dir = joinpath(homedir(), ".rr")
        xdg_dir = if haskey(ENV, "XDG_DATA_HOME")
            joinpath(ENV["XDG_DATA_HOME"], "rr")
        else
            joinpath(homedir(), ".local", "share", "rr")
        end
        if !isdir(xdg_dir) && isdir(dot_dir)
            # backwards compatibility
            dot_dir
        else
            xdg_dir
        end
    end
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
                   trace_dir=default_rr_trace_dir(), timeout=0, extras=false)
    check_rr_available()
    check_perf_event_paranoid(; rr_flags=rr_flags)

    new_env = copy(ENV)
    new_env["_RR_TRACE_DIR"] = trace_dir

    # loading GDB_jll sets PYTHONHOME through Python_jll. this only matters for replay,
    # and shouldn't leak into the record environment (where we may load another Python)
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
                @async Timer(timeout) do timer
                    istaskdone(t1) || Base.throwto(t1, InterruptException())
                end
            end
        end
        return proc
    end

    if extras
        # we know that the currently executing Julia process matches the one we'll record,
        # so gather some additional information and add it to the trace
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
        open(joinpath(find_latest_trace(trace_dir), "julia_metadata.json"), "w") do io
            JSON.print(io, metadata)
        end

        # add standard library sources to the trace
        # XXX: the Base stdlib sources can be found in here as well, as a symlink to their
        #      location in the Julia repository, but we don't copy them (i.e. we don't set
        #      follow_symlinks=true) because (1) the DW_AT_name debug info always points to
        #      the source location anyway, and (2) some of these symlinks have been noticed
        #      to be broken which could break trace recording.
        cp(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia"),
           joinpath(find_latest_trace(trace_dir), "julia_sources"))
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
    # extract, cached for the duration of this session
    trace_dir = joinpath(trace_cache, basename(trace_file))
    if !isdir(trace_dir)
        decompress_rr_trace(trace_file, trace_dir)
    end
    return trace_dir
end

function download_rr_trace(trace_url)
    p = nothing
    function update_progress(total::Int, now::Int)
        if p === nothing && total > 0 && now != total
            p = Progress(total; desc="Downloading trace: ")
        end
        if p !== nothing
            update!(p, now)
        end
        if now == total
            p = nothing
        end
        return
    end
    progress = isinteractive() ? update_progress : nothing

    # download and extract, cached for the duration of this session
    trace_dir = joinpath(trace_cache, basename(trace_url))
    if !isdir(trace_dir)
        mktempdir() do dl_dir
            local_path = joinpath(dl_dir, "trace.tar.zst")
            Downloads.download(trace_url, local_path; progress=progress)
            decompress_rr_trace(local_path, trace_dir)
        end
    end
    return trace_dir
end

function get_sourcecode(commit)
    # core check-out
    if !ispath(joinpath(julia_checkout, "config"))
        println("Checking-out Julia source code, this may take a minute...")
        run(`$(git()) clone --quiet --bare https://github.com/JuliaLang/julia.git $julia_checkout`)
    end

    # explicitly fetch the requested commit from the remote and put it on the master branch.
    # we need to do this as not all commits (e.g. merge heads) might be available locally
    if !success(`$(git()) -C $julia_checkout fetch --quiet --force origin $commit:master`)
        @error "Could not fetch commit $commit from the Julia repository."
        return nothing
    end

    # check-out source code
    dir = mktempdir()
    run(`$(git()) clone --quiet --branch master $julia_checkout $dir`)
    return dir
end

function replay(trace_url=default_rr_trace_dir(); gdb_commands=[], gdb_flags=``,
                rr_replay_flags=``)
    # download remote traces
    if startswith(trace_url, "s3://")
        trace_url = string("https://s3.amazonaws.com/julialang-dumps/", trace_url[6:end])
    end
    if startswith(trace_url, "http://") || startswith(trace_url, "https://")
        trace_url = download_rr_trace(trace_url)
        rr_replay_flags = `$rr_replay_flags --serve-files`
        # for remote traces, we assume it originated on a different system, so we need to
        # tell rr to serve files as it's unlikely they will be available locally.
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

    # determine GDB arguments
    gdb_args = `$gdb_flags`
    if metadata !== nothing
        # standard library sources are part of the trace
        stdlib_sources = joinpath(trace_dir, "julia_sources")
        if ispath(stdlib_sources)
            if haskey(metadata, "comp_dir")
                gdb_args = `$gdb_args -ex "set substitute-path $(metadata["comp_dir"])/usr/share/julia $stdlib_sources"`
            else
                # we don't really want to add a `directory` entry for every stdlib subdir
            end
        end

        # Julia source code is fetched from Git. this needs to happen after adding standard
        # library sources because the checkout directory typically contains the system image
        # (as we build into `$checkout/usr`) and the rules are order sensitive.
        julia_source = get_sourcecode(metadata["commit"])
        if julia_source !== nothing
            if haskey(metadata, "comp_dir")
                gdb_args = `$gdb_args -ex "set substitute-path $(metadata["comp_dir"]) $julia_source"`
            else
                gdb_args = `$gdb_args -ex "directory $(joinpath(julia_source, "src"))"`
            end

            # the Base stdlib is part of the Julia repository
            gdb_args = `$gdb_args -ex "directory $(joinpath(julia_source, "base"))"`
        else
            @warn "Could not find the source code for Julia commit $commit."
        end
    end
    for gdb_command in gdb_commands
        gdb_args = `$gdb_args -ex "$gdb_command"`
    end

    # replay with rr
    proc = rr() do rr_path
        gdb() do gdb_path
            run(`$rr_path replay $rr_replay_flags -d $gdb_path $trace_dir -- $gdb_args`)
        end
    end

    # clean-up
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

    if report_type == "rr-local"
        proc = rr_record(cmd, ARGS...; timeout=timeout, extras=true)
        handle_child_error(proc)
    elseif report_type == "rr"
        mktempdir() do trace_dir
            proc = rr_record(cmd, ARGS...; trace_dir=trace_dir, timeout=timeout, extras=true)
            "Preparing trace for upload (if your trace is large this may take a few minutes)..."
            rr_pack(trace_dir)
            params = get_upload_params()
            if params !== nothing
                path, creds = params

                println("Uploading trace...")
                withenv("AWS_REGION" => "us-east-1") do
                    upload_rr_trace(trace_dir, "s3://$TRACE_BUCKET/$path"; creds...)
                end
                println("Uploaded to https://$TRACE_BUCKET.s3.amazonaws.com/$path")
            end
            handle_child_error(proc)
        end
    else
        error("Unknown report type: $report_type")
    end
end

include("sync_compat.jl")

function get_upload_params()
    # big disclaimer
    println()
    printstyled("### IMPORTANT =============================================================\n", blink = true)
    println("""
        You are about to upload a trace directory to a publicly accessible location.
        Such traces contain any information that was accessed by the traced
        executable during its execution. This includes any code loaded, any
        secrets entered, the contents of any configuration files, etc.

        DO NOT proceed, if you do not wish to make this information publicly available.
        By proceeding you explicitly agree to waive any privacy interest in the
        uploaded information.""")
    printstyled("### =======================================================================\n", blink = true)
    println()

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

    println("To upload a trace, please authenticate by visiting:\n")
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

    return s3creds["UPLOAD_PATH"], (; access_key_id=s3creds["AWS_ACCESS_KEY_ID"],
                                      secret_access_key=s3creds["AWS_SECRET_ACCESS_KEY"],
                                      session_token=s3creds["AWS_SESSION_TOKEN"])
end

function upload_rr_trace(trace_directory, url; access_key_id, secret_access_key, session_token)
    # Auto-pack this trace directory if it hasn't already been:
    sample_directory = joinpath(trace_directory, "latest-trace")
    if isdir(sample_directory) && uperm(sample_directory) & 0x2 == 0
        println("`$sample_directory` not writable. Skipping `rr pack`.")
    else
        rr_pack(trace_directory)
    end

    mktempdir() do dir
        # Create a compressed tarball
        # TODO: stream (peak/s5cmd#182)
        tarball = joinpath(dir, "trace.tar")
        Tar.create(trace_directory, tarball)
        zstdmt() do zstdp
            run(`$zstdp --quiet $tarball`)
        end

        # Upload
        # TODO: progress bar (peak/s5cmd#51)
        cmd = `$(s5cmd()) --log error cp $(tarball).zst $url`
        cmd = addenv(cmd, "AWS_ACCESS_KEY_ID" => access_key_id,
                          "AWS_SECRET_ACCESS_KEY" => secret_access_key,
                          "AWS_SESSION_TOKEN" => session_token)
        run(cmd)
    end
end

function __init__()
    if haskey(ENV, "JULIA_RR_RECORD_ARGS")
        global default_rr_record_flags = eval(:(@cmd($(ENV["JULIA_RR_RECORD_ARGS"]))))
    end

    global julia_checkout = @get_scratch!("julia")
    global trace_cache = mktempdir()
end


end # module
