#!/usr/bin/env python3
"""Minimal boto3 compatibility check used by verify-clients.sh."""

import os

import boto3
from botocore.config import Config


endpoint = os.environ.get("ZS3_ENDPOINT", "http://127.0.0.1:9000")
access_key = os.environ.get("ZS3_ACCESS_KEY", "minioadmin")
secret_key = os.environ.get("ZS3_SECRET_KEY", "minioadmin")
bucket = os.environ["ZS3_TEST_BUCKET"]
key = "boto3/compatibility.txt"
payload = b"zs3-boto3-compatible\n"

client = boto3.client(
    "s3",
    endpoint_url=endpoint,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    region_name="us-east-1",
    config=Config(s3={"addressing_style": "path"}),
)

try:
    client.create_bucket(Bucket=bucket)
    client.put_object(Bucket=bucket, Key=key, Body=payload)
    assert client.head_object(Bucket=bucket, Key=key)["ContentLength"] == len(payload)
    assert client.get_object(Bucket=bucket, Key=key)["Body"].read() == payload
    keys = [item["Key"] for item in client.list_objects_v2(Bucket=bucket).get("Contents", [])]
    assert key in keys
    client.delete_object(Bucket=bucket, Key=key)
    client.delete_bucket(Bucket=bucket)
except Exception:
    try:
        client.delete_object(Bucket=bucket, Key=key)
        client.delete_bucket(Bucket=bucket)
    except Exception:
        pass
    raise

print(f"PASS boto3 {boto3.__version__}")
