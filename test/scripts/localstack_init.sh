#!/usr/bin/env bash
echo "Init localstack s3"
awslocal s3 mb s3://test-bucket
