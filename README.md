# BugReporting.jl

This package implements Julia's `--bug-report` flag, simplyfing bug reporting by enabling
users to easily generate and upload reports to help developers fix bugs.

```
    julia --bug-report=REPORT_TYPE[,REPORT_FLAG,...]
```

Currently, only the [rr](https://github.com/rr-debugger/rr) tool is supported to generate
bug reports, but in the future other types of reports may be supported as well.


## Available bug report types and flags

### `--bug-report=help`

Print help message and exit.

### `--bug-report=rr`

Run `julia` inside `rr record` and upload the recorded trace.

### `--bug-report=rr-local`

Run `julia` inside `rr record` but do not upload the recorded trace. Useful for local debugging.

### `--bug-report=XXX,timeout=SECONDS`

Generate a bug report, but limit the execution time of the debugged process to `SECONDS` seconds.
This is useful for generating reports for hangs.


## Using the traces for local debugging

You can use this package also for debugging your own Julia code locally. Use `--bug-report=rr-local`
to record a trace, and `replay(PATH)` to replay a trace.

For example, if you have a script in a project that you'd like to trace, run `julia --bug-report=rr -- --project=foo run.jl`.
