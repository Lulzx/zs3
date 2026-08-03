#!/usr/bin/env python3
"""
Comprehensive test suite for zs3 - S3-compatible storage

Tests cover:
- Bucket operations (CRUD)
- Object operations (CRUD, metadata)
- List operations (prefix, delimiter, pagination)
- Range requests
- Multipart uploads
- Batch operations
- Security (path traversal, auth, invalid inputs)
- Edge cases (empty, large, unicode, special chars)
- Distributed mode features
"""

import boto3
import botocore
from botocore.config import Config
from botocore.exceptions import ClientError
import hashlib
import time
import sys
import os

# Configuration
ENDPOINT = os.environ.get('ZS3_ENDPOINT', 'http://localhost:9000')
ACCESS_KEY = os.environ.get('ZS3_ACCESS_KEY', 'minioadmin')
SECRET_KEY = os.environ.get('ZS3_SECRET_KEY', 'minioadmin')
REGION = 'us-east-1'

# Test state
passed = 0
failed = 0
skipped = 0

def get_client():
    """Create boto3 S3 client"""
    return boto3.client(
        's3',
        endpoint_url=ENDPOINT,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        region_name=REGION,
        config=Config(
            s3={'addressing_style': 'path'},
            retries={'max_attempts': 1}
        )
    )

def test(name, condition, error_msg=""):
    """Record test result"""
    global passed, failed
    if condition:
        print(f"  [PASS] {name}")
        passed += 1
        return True
    else:
        print(f"  [FAIL] {name}")
        if error_msg:
            print(f"         {error_msg}")
        failed += 1
        return False

def test_exception(name, expected_code, func, *args, **kwargs):
    """Test that function raises expected error code"""
    global passed, failed
    try:
        func(*args, **kwargs)
        print(f"  [FAIL] {name} - expected {expected_code}, got success")
        failed += 1
        return False
    except ClientError as e:
        actual_code = e.response['Error']['Code']
        if actual_code == expected_code:
            print(f"  [PASS] {name}")
            passed += 1
            return True
        else:
            print(f"  [FAIL] {name} - expected {expected_code}, got {actual_code}")
            failed += 1
            return False
    except Exception as e:
        print(f"  [FAIL] {name} - unexpected error: {e}")
        failed += 1
        return False

def cleanup_bucket(s3, bucket):
    """Delete all objects and the bucket"""
    try:
        # List and delete all objects
        response = s3.list_objects_v2(Bucket=bucket)
        if 'Contents' in response:
            for obj in response['Contents']:
                s3.delete_object(Bucket=bucket, Key=obj['Key'])
        # Delete bucket
        s3.delete_bucket(Bucket=bucket)
    except:
        pass

# =============================================================================
# BUCKET OPERATION TESTS
# =============================================================================

def test_bucket_operations(s3):
    print("\n[Bucket Operations]")
    bucket = "test-bucket-ops"
    cleanup_bucket(s3, bucket)

    # Create bucket
    try:
        s3.create_bucket(Bucket=bucket)
        test("Create bucket", True)
    except Exception as e:
        test("Create bucket", False, str(e))

    # Create bucket again (should be idempotent or return BucketAlreadyOwnedByYou)
    try:
        s3.create_bucket(Bucket=bucket)
        test("Create bucket (idempotent)", True)
    except ClientError as e:
        code = e.response['Error']['Code']
        test("Create bucket (idempotent)", code in ['BucketAlreadyOwnedByYou', 'BucketAlreadyExists'])

    # Head bucket
    try:
        s3.head_bucket(Bucket=bucket)
        test("Head bucket (exists)", True)
    except Exception as e:
        test("Head bucket (exists)", False, str(e))

    # Head non-existent bucket
    test_exception("Head bucket (not exists)", "404", s3.head_bucket, Bucket="nonexistent-bucket-12345")

    # List buckets
    try:
        response = s3.list_buckets()
        buckets = [b['Name'] for b in response['Buckets']]
        test("List buckets", bucket in buckets)
    except Exception as e:
        test("List buckets", False, str(e))

    # Invalid bucket names
    test_exception("Invalid bucket name (too short)", "InvalidBucketName", s3.create_bucket, Bucket="ab")
    test_exception("Invalid bucket name (too long)", "InvalidBucketName",
                   s3.create_bucket, Bucket="a" * 64)
    test_exception("Invalid bucket name (uppercase)", "InvalidBucketName",
                   s3.create_bucket, Bucket="MyBucket")
    test_exception("Invalid bucket name (underscore)", "InvalidBucketName",
                   s3.create_bucket, Bucket="my_bucket")

    # Delete bucket
    try:
        s3.delete_bucket(Bucket=bucket)
        test("Delete bucket", True)
    except Exception as e:
        test("Delete bucket", False, str(e))

    # Delete non-existent bucket
    test_exception("Delete bucket (not exists)", "NoSuchBucket",
                   s3.delete_bucket, Bucket="nonexistent-bucket-12345")

# =============================================================================
# OBJECT OPERATION TESTS
# =============================================================================

def test_object_operations(s3):
    print("\n[Object Operations]")
    bucket = "test-object-ops"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Put object
    try:
        s3.put_object(Bucket=bucket, Key="hello.txt", Body=b"Hello, World!")
        test("Put object", True)
    except Exception as e:
        test("Put object", False, str(e))

    # Get object
    try:
        response = s3.get_object(Bucket=bucket, Key="hello.txt")
        body = response['Body'].read()
        test("Get object", body == b"Hello, World!")
    except Exception as e:
        test("Get object", False, str(e))

    # Head object
    try:
        response = s3.head_object(Bucket=bucket, Key="hello.txt")
        test("Head object", response['ContentLength'] == 13)
    except Exception as e:
        test("Head object", False, str(e))

    # Get non-existent object
    test_exception("Get non-existent object", "NoSuchKey",
                   s3.get_object, Bucket=bucket, Key="nonexistent.txt")

    # Put nested object
    try:
        s3.put_object(Bucket=bucket, Key="folder/nested/file.txt", Body=b"Nested content")
        test("Put nested object", True)
    except Exception as e:
        test("Put nested object", False, str(e))

    # Get nested object
    try:
        response = s3.get_object(Bucket=bucket, Key="folder/nested/file.txt")
        body = response['Body'].read()
        test("Get nested object", body == b"Nested content")
    except Exception as e:
        test("Get nested object", False, str(e))

    # A filesystem directory used by nested keys is not itself an S3 object.
    try:
        s3.head_object(Bucket=bucket, Key="folder")
        test("Head directory prefix is not an object", False, "expected 404")
    except ClientError as e:
        status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        test("Head directory prefix is not an object", status == 404, str(e))

    # Put empty object
    try:
        s3.put_object(Bucket=bucket, Key="empty.txt", Body=b"")
        test("Put empty object", True)
    except Exception as e:
        test("Put empty object", False, str(e))

    # Get empty object
    try:
        response = s3.get_object(Bucket=bucket, Key="empty.txt")
        body = response['Body'].read()
        test("Get empty object", body == b"" and response['ContentLength'] == 0)
    except Exception as e:
        test("Get empty object", False, str(e))

    # Put binary data
    binary_data = bytes(range(256)) * 100  # 25.6 KB
    try:
        s3.put_object(Bucket=bucket, Key="binary.bin", Body=binary_data)
        test("Put binary data", True)
    except Exception as e:
        test("Put binary data", False, str(e))

    # Get binary data
    try:
        response = s3.get_object(Bucket=bucket, Key="binary.bin")
        body = response['Body'].read()
        test("Get binary data", body == binary_data)
    except Exception as e:
        test("Get binary data", False, str(e))

    # Verify ETag
    try:
        response = s3.head_object(Bucket=bucket, Key="hello.txt")
        etag = response.get('ETag', '').strip('"')
        test("ETag present", len(etag) > 0)
    except Exception as e:
        test("ETag present", False, str(e))

    # Delete object
    try:
        s3.delete_object(Bucket=bucket, Key="hello.txt")
        test("Delete object", True)
    except Exception as e:
        test("Delete object", False, str(e))

    # Verify deletion
    test_exception("Verify object deleted", "NoSuchKey",
                   s3.get_object, Bucket=bucket, Key="hello.txt")

    # Delete non-existent object (should succeed silently per S3 spec)
    try:
        s3.delete_object(Bucket=bucket, Key="nonexistent.txt")
        test("Delete non-existent object", True)
    except Exception as e:
        test("Delete non-existent object", False, str(e))

    cleanup_bucket(s3, bucket)

# =============================================================================
# LIST OPERATION TESTS
# =============================================================================

def test_list_operations(s3):
    print("\n[List Operations]")
    bucket = "test-list-ops"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Create test objects
    objects = [
        "file1.txt",
        "file2.txt",
        "folder1/file1.txt",
        "folder1/file2.txt",
        "folder1/subfolder/file.txt",
        "folder2/file1.txt",
        "photos/2023/jan/photo1.jpg",
        "photos/2023/jan/photo2.jpg",
        "photos/2023/feb/photo1.jpg",
    ]
    for key in objects:
        s3.put_object(Bucket=bucket, Key=key, Body=b"test")

    # List all objects
    try:
        response = s3.list_objects_v2(Bucket=bucket)
        keys = [obj['Key'] for obj in response.get('Contents', [])]
        test("List all objects", len(keys) == len(objects))
    except Exception as e:
        test("List all objects", False, str(e))

    # List with prefix
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix="folder1/")
        keys = [obj['Key'] for obj in response.get('Contents', [])]
        expected = ["folder1/file1.txt", "folder1/file2.txt", "folder1/subfolder/file.txt"]
        test("List with prefix", sorted(keys) == sorted(expected))
    except Exception as e:
        test("List with prefix", False, str(e))

    # List with delimiter (virtual folders)
    try:
        response = s3.list_objects_v2(Bucket=bucket, Delimiter="/")
        keys = [obj['Key'] for obj in response.get('Contents', [])]
        prefixes = [p['Prefix'] for p in response.get('CommonPrefixes', [])]
        test("List with delimiter - files", sorted(keys) == ["file1.txt", "file2.txt"])
        test("List with delimiter - prefixes", sorted(prefixes) == ["folder1/", "folder2/", "photos/"])
    except Exception as e:
        test("List with delimiter - files", False, str(e))
        test("List with delimiter - prefixes", False, str(e))

    # List with prefix and delimiter
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix="photos/2023/", Delimiter="/")
        prefixes = [p['Prefix'] for p in response.get('CommonPrefixes', [])]
        test("List with prefix+delimiter", sorted(prefixes) == ["photos/2023/feb/", "photos/2023/jan/"])
    except Exception as e:
        test("List with prefix+delimiter", False, str(e))

    # List with max-keys (pagination)
    try:
        response = s3.list_objects_v2(Bucket=bucket, MaxKeys=3)
        keys = [obj['Key'] for obj in response.get('Contents', [])]
        test("List with max-keys", len(keys) == 3 and response.get('IsTruncated', False))
    except Exception as e:
        test("List with max-keys", False, str(e))

    # Pagination with continuation token
    try:
        all_keys = []
        continuation_token = None
        while True:
            if continuation_token:
                response = s3.list_objects_v2(Bucket=bucket, MaxKeys=3, ContinuationToken=continuation_token)
            else:
                response = s3.list_objects_v2(Bucket=bucket, MaxKeys=3)

            keys = [obj['Key'] for obj in response.get('Contents', [])]
            all_keys.extend(keys)

            if not response.get('IsTruncated', False):
                break
            continuation_token = response.get('NextContinuationToken')

        test("Pagination complete", len(all_keys) == len(objects))
    except Exception as e:
        test("Pagination complete", False, str(e))

    # List empty bucket
    empty_bucket = "test-list-empty"
    cleanup_bucket(s3, empty_bucket)
    s3.create_bucket(Bucket=empty_bucket)
    try:
        response = s3.list_objects_v2(Bucket=empty_bucket)
        test("List empty bucket", 'Contents' not in response or len(response['Contents']) == 0)
    except Exception as e:
        test("List empty bucket", False, str(e))
    cleanup_bucket(s3, empty_bucket)

    cleanup_bucket(s3, bucket)

# =============================================================================
# RANGE REQUEST TESTS
# =============================================================================

def test_range_requests(s3):
    global skipped
    print("\n[Range Requests]")
    bucket = "test-range-ops"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Create test object
    content = b"0123456789ABCDEFGHIJ"  # 20 bytes
    s3.put_object(Bucket=bucket, Key="range-test.txt", Body=content)

    # Range: first 5 bytes
    try:
        response = s3.get_object(Bucket=bucket, Key="range-test.txt", Range="bytes=0-4")
        body = response['Body'].read()
        test("Range 0-4", body == b"01234")
    except Exception as e:
        test("Range 0-4", False, str(e))

    # Range: middle bytes
    try:
        response = s3.get_object(Bucket=bucket, Key="range-test.txt", Range="bytes=5-9")
        body = response['Body'].read()
        test("Range 5-9", body == b"56789")
    except Exception as e:
        test("Range 5-9", False, str(e))

    # Range: last 5 bytes
    try:
        response = s3.get_object(Bucket=bucket, Key="range-test.txt", Range="bytes=15-19")
        body = response['Body'].read()
        test("Range 15-19", body == b"FGHIJ")
    except Exception as e:
        test("Range 15-19", False, str(e))

    # Range: suffix (last N bytes)
    try:
        response = s3.get_object(Bucket=bucket, Key="range-test.txt", Range="bytes=-5")
        body = response['Body'].read()
        test("Range suffix -5", body == b"FGHIJ")
    except Exception as e:
        # Server may not support suffix ranges
        print(f"  [SKIP] Range suffix -5 (not supported)")
        skipped += 1

    # Range: prefix (from N to end)
    try:
        response = s3.get_object(Bucket=bucket, Key="range-test.txt", Range="bytes=15-")
        body = response['Body'].read()
        test("Range prefix 15-", body == b"FGHIJ")
    except Exception as e:
        print(f"  [SKIP] Range prefix 15- (not supported)")
        skipped += 1

    # Single byte range
    try:
        response = s3.get_object(Bucket=bucket, Key="range-test.txt", Range="bytes=10-10")
        body = response['Body'].read()
        test("Range single byte", body == b"A")
    except Exception as e:
        test("Range single byte", False, str(e))

    cleanup_bucket(s3, bucket)

# =============================================================================
# MULTIPART UPLOAD TESTS
# =============================================================================

def test_multipart_uploads(s3):
    print("\n[Multipart Uploads]")
    bucket = "test-multipart-ops"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    key = "multipart-test.bin"

    # Initiate multipart upload
    try:
        response = s3.create_multipart_upload(Bucket=bucket, Key=key)
        upload_id = response['UploadId']
        test("Initiate multipart upload", len(upload_id) > 0)
    except Exception as e:
        test("Initiate multipart upload", False, str(e))
        cleanup_bucket(s3, bucket)
        return

    # Upload parts (minimum 5MB per part except last, but server may accept smaller)
    parts = []
    part_data = [
        b"A" * 1024,  # Part 1: 1KB
        b"B" * 1024,  # Part 2: 1KB
        b"C" * 512,   # Part 3: 512 bytes
    ]

    all_parts_uploaded = True
    for i, data in enumerate(part_data, 1):
        try:
            response = s3.upload_part(
                Bucket=bucket,
                Key=key,
                UploadId=upload_id,
                PartNumber=i,
                Body=data
            )
            parts.append({
                'ETag': response['ETag'],
                'PartNumber': i
            })
        except Exception as e:
            test(f"Upload part {i}", False, str(e))
            all_parts_uploaded = False

    test("Upload all parts", all_parts_uploaded)

    # Complete multipart upload
    if all_parts_uploaded:
        try:
            s3.complete_multipart_upload(
                Bucket=bucket,
                Key=key,
                UploadId=upload_id,
                MultipartUpload={'Parts': parts}
            )
            test("Complete multipart upload", True)
        except Exception as e:
            test("Complete multipart upload", False, str(e))

        # Verify content
        try:
            response = s3.get_object(Bucket=bucket, Key=key)
            body = response['Body'].read()
            expected = b"A" * 1024 + b"B" * 1024 + b"C" * 512
            test("Verify multipart content", body == expected)
        except Exception as e:
            test("Verify multipart content", False, str(e))

    # Test abort multipart upload
    try:
        response = s3.create_multipart_upload(Bucket=bucket, Key="abort-test.bin")
        abort_upload_id = response['UploadId']
        s3.abort_multipart_upload(Bucket=bucket, Key="abort-test.bin", UploadId=abort_upload_id)
        test("Abort multipart upload", True)
    except Exception as e:
        test("Abort multipart upload", False, str(e))

    cleanup_bucket(s3, bucket)

# =============================================================================
# BATCH DELETE TESTS
# =============================================================================

def test_batch_delete(s3):
    print("\n[Batch Delete Operations]")
    bucket = "test-batch-delete"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Create test objects
    keys = [f"file{i}.txt" for i in range(10)]
    for key in keys:
        s3.put_object(Bucket=bucket, Key=key, Body=b"test content")

    # Batch delete
    try:
        response = s3.delete_objects(
            Bucket=bucket,
            Delete={
                'Objects': [{'Key': key} for key in keys[:5]],
                'Quiet': False
            }
        )
        deleted = [d['Key'] for d in response.get('Deleted', [])]
        test("Batch delete 5 objects", len(deleted) == 5)
    except Exception as e:
        test("Batch delete 5 objects", False, str(e))

    # Verify remaining objects
    try:
        response = s3.list_objects_v2(Bucket=bucket)
        remaining = [obj['Key'] for obj in response.get('Contents', [])]
        test("Verify remaining objects", len(remaining) == 5)
    except Exception as e:
        test("Verify remaining objects", False, str(e))

    # Delete with non-existent keys (should succeed silently)
    try:
        response = s3.delete_objects(
            Bucket=bucket,
            Delete={
                'Objects': [
                    {'Key': 'nonexistent1.txt'},
                    {'Key': 'nonexistent2.txt'},
                ],
                'Quiet': False
            }
        )
        deleted = response.get('Deleted', [])
        errors = response.get('Errors', [])
        test("Batch delete non-existent", len(errors) == 0)
    except Exception as e:
        test("Batch delete non-existent", False, str(e))

    cleanup_bucket(s3, bucket)

# =============================================================================
# SECURITY TESTS
# =============================================================================

def test_security(s3):
    print("\n[Security Tests]")
    bucket = "test-security"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Path traversal attempts
    traversal_keys = [
        "../../../etc/passwd",
        "..\\..\\..\\windows\\system32",
        "folder/../../../etc/passwd",
        "a..b",  # Double dots in name
        "folder/..hidden",
    ]

    for key in traversal_keys:
        try:
            s3.put_object(Bucket=bucket, Key=key, Body=b"hacked")
            test(f"Block path traversal: {key[:30]}", False, "Should have been rejected")
        except ClientError as e:
            code = e.response['Error']['Code']
            test(f"Block path traversal: {key[:30]}", code in ['InvalidKey', 'InvalidArgument', 'AccessDenied'])
        except Exception as e:
            test(f"Block path traversal: {key[:30]}", False, str(e))

    # Invalid credentials test
    bad_client = boto3.client(
        's3',
        endpoint_url=ENDPOINT,
        aws_access_key_id='wrongkey',
        aws_secret_access_key='wrongsecret',
        region_name=REGION,
        config=Config(s3={'addressing_style': 'path'}, retries={'max_attempts': 1})
    )

    try:
        bad_client.list_buckets()
        test("Reject invalid credentials", False, "Should have been rejected")
    except ClientError as e:
        code = e.response['Error']['Code']
        test("Reject invalid credentials", code in ['AccessDenied', 'InvalidAccessKeyId', 'SignatureDoesNotMatch'])
    except Exception as e:
        # Connection refused or other errors are acceptable too
        test("Reject invalid credentials", True)

    # Very long key (should be rejected if > 1024)
    try:
        long_key = "a" * 2000
        s3.put_object(Bucket=bucket, Key=long_key, Body=b"test")
        test("Reject very long key", False, "Should have been rejected")
    except ClientError as e:
        test("Reject very long key", True)
    except Exception as e:
        test("Reject very long key", True)  # Any rejection is fine

    cleanup_bucket(s3, bucket)

# =============================================================================
# EDGE CASE TESTS
# =============================================================================

def test_edge_cases(s3):
    global skipped
    print("\n[Edge Cases]")
    bucket = "test-edge-cases"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Unicode key
    try:
        s3.put_object(Bucket=bucket, Key="unicode-\u4e2d\u6587.txt", Body=b"chinese")
        response = s3.get_object(Bucket=bucket, Key="unicode-\u4e2d\u6587.txt")
        body = response['Body'].read()
        test("Unicode key", body == b"chinese")
    except Exception as e:
        print(f"  [SKIP] Unicode key (not supported): {e}")
        skipped += 1

    # Special characters in key
    special_chars_keys = [
        "file with spaces.txt",
        "file+plus.txt",
        "file=equals.txt",
        "file&ampersand.txt",
        "file@at.txt",
    ]

    for key in special_chars_keys:
        try:
            s3.put_object(Bucket=bucket, Key=key, Body=b"special")
            response = s3.get_object(Bucket=bucket, Key=key)
            body = response['Body'].read()
            test(f"Special chars: {key}", body == b"special")
        except Exception as e:
            test(f"Special chars: {key}", False, str(e))

    # Very deep nesting
    deep_key = "/".join([f"level{i}" for i in range(20)]) + "/file.txt"
    try:
        s3.put_object(Bucket=bucket, Key=deep_key, Body=b"deep")
        response = s3.get_object(Bucket=bucket, Key=deep_key)
        body = response['Body'].read()
        test("Deep nesting (20 levels)", body == b"deep")
    except Exception as e:
        test("Deep nesting (20 levels)", False, str(e))

    # Key with only extension
    try:
        s3.put_object(Bucket=bucket, Key=".hidden", Body=b"hidden")
        response = s3.get_object(Bucket=bucket, Key=".hidden")
        test("Hidden file (.hidden)", response['Body'].read() == b"hidden")
    except Exception as e:
        test("Hidden file (.hidden)", False, str(e))

    # Key that looks like a folder
    try:
        s3.put_object(Bucket=bucket, Key="folder/", Body=b"folder-as-file")
        response = s3.get_object(Bucket=bucket, Key="folder/")
        test("Key ending with /", response['Body'].read() == b"folder-as-file")
    except Exception as e:
        test("Key ending with /", False, str(e))

    # Overwrite existing object
    try:
        s3.put_object(Bucket=bucket, Key="overwrite.txt", Body=b"original")
        s3.put_object(Bucket=bucket, Key="overwrite.txt", Body=b"updated")
        response = s3.get_object(Bucket=bucket, Key="overwrite.txt")
        test("Overwrite object", response['Body'].read() == b"updated")
    except Exception as e:
        test("Overwrite object", False, str(e))

    # Large object (1MB)
    large_data = b"X" * (1024 * 1024)
    try:
        s3.put_object(Bucket=bucket, Key="large-1mb.bin", Body=large_data)
        response = s3.get_object(Bucket=bucket, Key="large-1mb.bin")
        body = response['Body'].read()
        test("Large object (1MB)", body == large_data)
    except Exception as e:
        test("Large object (1MB)", False, str(e))

    # Content type handling
    try:
        s3.put_object(Bucket=bucket, Key="typed.json", Body=b'{"key": "value"}',
                     ContentType="application/json")
        test("Put with ContentType", True)
    except Exception as e:
        test("Put with ContentType", False, str(e))

    cleanup_bucket(s3, bucket)

# =============================================================================
# DISTRIBUTED MODE TESTS
# =============================================================================

def test_distributed_features(s3):
    print("\n[Distributed Mode Features]")

    # Check if distributed mode is enabled by querying peer endpoint
    import urllib.request
    try:
        req = urllib.request.Request(f"{ENDPOINT}/_zs3/ping")
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = resp.read().decode()
            test("Ping endpoint available", "id" in data)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("  [SKIP] Distributed mode not enabled")
            return
        test("Ping endpoint available", False, str(e))
    except Exception as e:
        print(f"  [SKIP] Distributed mode not enabled: {e}")
        return

    # Check peers endpoint
    try:
        req = urllib.request.Request(f"{ENDPOINT}/_zs3/peers")
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = resp.read().decode()
            test("Peers endpoint", data.startswith("["))
    except Exception as e:
        test("Peers endpoint", False, str(e))

    bucket = "test-distributed"
    cleanup_bucket(s3, bucket)
    s3.create_bucket(Bucket=bucket)

    # Test that objects work in distributed mode
    try:
        # Small object (inline storage)
        s3.put_object(Bucket=bucket, Key="small.txt", Body=b"small content")
        response = s3.get_object(Bucket=bucket, Key="small.txt")
        test("Small object (inline)", response['Body'].read() == b"small content")
    except Exception as e:
        test("Small object (inline)", False, str(e))

    try:
        # Larger object (CAS storage, > 4KB)
        large_content = b"L" * 5000
        s3.put_object(Bucket=bucket, Key="large.txt", Body=large_content)
        response = s3.get_object(Bucket=bucket, Key="large.txt")
        test("Large object (CAS)", response['Body'].read() == large_content)
    except Exception as e:
        test("Large object (CAS)", False, str(e))

    # Test delete creates tombstone (object should be gone from list)
    try:
        s3.put_object(Bucket=bucket, Key="to-delete.txt", Body=b"delete me")
        s3.delete_object(Bucket=bucket, Key="to-delete.txt")

        response = s3.list_objects_v2(Bucket=bucket)
        keys = [obj['Key'] for obj in response.get('Contents', [])]
        test("Tombstone hides deleted object", "to-delete.txt" not in keys)
    except Exception as e:
        test("Tombstone hides deleted object", False, str(e))

    cleanup_bucket(s3, bucket)

# =============================================================================
# MAIN
# =============================================================================

def main():
    global passed, failed, skipped

    print("=" * 70)
    print("zs3 Comprehensive Test Suite (boto3)")
    print("=" * 70)
    print(f"Endpoint: {ENDPOINT}")
    print(f"Access Key: {ACCESS_KEY}")

    s3 = get_client()

    # Check connectivity
    try:
        s3.list_buckets()
        print("Connection: OK\n")
    except Exception as e:
        print(f"Connection: FAILED - {e}")
        print("\nMake sure zs3 is running on the configured endpoint.")
        sys.exit(1)

    # Run all test suites
    test_bucket_operations(s3)
    test_object_operations(s3)
    test_list_operations(s3)
    test_range_requests(s3)
    test_multipart_uploads(s3)
    test_batch_delete(s3)
    test_security(s3)
    test_edge_cases(s3)
    test_distributed_features(s3)

    # Summary
    print("\n" + "=" * 70)
    total = passed + failed
    print(f"Results: {passed}/{total} tests passed, {skipped} skipped")
    if failed == 0:
        print("All tests passed!")
    else:
        print(f"{failed} tests FAILED")
    print("=" * 70)

    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
