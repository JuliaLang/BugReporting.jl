#!/bin/sh

# Check for a `go` version new enough installed locally
if [ -n `which go` ]; then
    GOVERS_MINOR=`go version | sed -E 's/.*go1\.([0-9]+).*/\1/'`
    if [ -z "${GOVERS_MINOR}" ] || [ "${GOVERS_MINOR}" -lt 11 ]; then
        echo "go too old or doesn't run properly; autodetected version '1.${GOVERS_MINOR}'" >&2
    else
        GO_CMD="go build"
    fi
else
    echo "No go installation found!" >&2
fi

if [ -z "${GO_CMD}" ] && [ -n `which docker` ]; then
    echo "Docker found, attempting docker build..."
    GO_CMD="docker run --rm -ti -v `pwd`:/app -w /app golang /bin/bash -c \"go build && chown `id -u`:`id -g` S3Vendor_go\""
fi

eval ${GO_CMD}

rm -f lambda.zip
zip lambda.zip S3Vendor_go
aws lambda update-function-code --region=us-east-1 --function-name github-authentication --zip-file fileb://lambda.zip
