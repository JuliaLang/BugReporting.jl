# BugReporting

This is a WIP to simplify bug reporting for julia by enabling users to easily
upload rr traces (and in the future potentially other report types).

## Available bug report types

### `--bug-report=rr`

Run `julia` inside `rr record` and upload the recorded trace.

### `--bug-report=help`

Print help message and exit.
