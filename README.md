# BugReporting

This is a WIP to simplify bug reporting for julia by enabling users to easily
upload rr traces (and in the future potentially other report types).

## Available bug report types

### `--bug-report=rr`

Run `julia` inside `rr record` and upload the recorded trace.

### `--bug-report=rr-local`

Run `julia` inside `rr record` but do not upload the recorded trace. Useful for local debugging.

### `--bug-report=help`

Print help message and exit.

## Using the traces for local debugging

You can use this package also for debugging your own Julia code locally. Use `--bug-report=rr-local`
to record a trace, and `replay(PATH)` to replay a trace.

For example, if you have a script in a project that you'd like to trace, run `julia --bug-report=rr -- --project=foo run.jl`.
