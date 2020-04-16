#!/bin/sh
go build
zip -f lambda.zip S3Vendor_go
aws lambda update-function-code --function-name github-authentication --zip-file lambda.zip
