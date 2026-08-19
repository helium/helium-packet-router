#!/bin/sh
set -e

echo "Initializing RustFS buckets..."

# Bucket both report uploaders write to in CT
aws --endpoint-url http://rustfs:9000 s3 mb s3://test-bucket 2>/dev/null || {
    echo "Bucket test-bucket already exists"
}

echo "RustFS initialization complete"
