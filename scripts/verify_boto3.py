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
    client.put_object(Bucket=bucket, Key=key, Body=payload,
                      ContentType="text/plain", Metadata={"tool": "boto3"})
    head = client.head_object(Bucket=bucket, Key=key)
    assert head["ContentLength"] == len(payload)
    assert head["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "text/plain", head
    assert head.get("Metadata") == {"tool": "boto3"}, head
    assert client.get_object(Bucket=bucket, Key=key)["Body"].read() == payload
    keys = [item["Key"] for item in client.list_objects_v2(Bucket=bucket).get("Contents", [])]
    assert key in keys
    # Server-side copy (aws s3 mv/sync, rclone move depend on it)
    client.copy_object(Bucket=bucket, Key="boto3/copied.txt",
                       CopySource={"Bucket": bucket, "Key": key})
    assert client.get_object(Bucket=bucket, Key="boto3/copied.txt")["Body"].read() == payload
    # Presigned GET (query-string SigV4, no Authorization header)
    presigned = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="us-east-1",
        config=Config(s3={"addressing_style": "path"}, signature_version="s3v4"),
    ).generate_presigned_url("get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=600)
    import urllib.request
    with urllib.request.urlopen(presigned) as response:
        assert response.read() == payload, response.status
    client.delete_object(Bucket=bucket, Key=key)
    client.delete_object(Bucket=bucket, Key="boto3/copied.txt")
    client.delete_bucket(Bucket=bucket)
except Exception:
    try:
        client.delete_object(Bucket=bucket, Key=key)
        client.delete_bucket(Bucket=bucket)
    except Exception:
        pass
    raise

print(f"PASS boto3 {boto3.__version__}")
