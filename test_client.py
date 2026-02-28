#!/usr/bin/env python3
"""Test client for zs3 - uses only stdlib"""
import hashlib
import hmac
from datetime import datetime, timezone
import urllib.request
import urllib.parse

HOST = "localhost:9000"
ACCESS_KEY = "minioadmin"
SECRET_KEY = "minioadmin"
REGION = "us-east-1"

def sign_request(method, path, query="", headers=None, payload=b""):
    """AWS SigV4 signing"""
    if headers is None:
        headers = {}

    t = datetime.now(timezone.utc)
    amz_date = t.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = t.strftime("%Y%m%d")

    payload_hash = hashlib.sha256(payload).hexdigest()
    headers["x-amz-date"] = amz_date
    headers["x-amz-content-sha256"] = payload_hash
    headers["host"] = HOST

    # Sort and format headers
    signed_headers = ";".join(sorted(k.lower() for k in headers))
    canonical_headers = "".join(f"{k.lower()}:{v}\n" for k, v in sorted(headers.items(), key=lambda x: x[0].lower()))

    # Sort query string - normalize bare params (e.g. "delete") to "delete="
    # to match server's sortQueryString behavior (required by SigV4)
    if query:
        pairs = [p if "=" in p else p + "=" for p in query.split("&")]
        pairs.sort()
        canonical_query = "&".join(pairs)
    else:
        canonical_query = ""

    canonical_request = f"{method}\n{path}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"

    credential_scope = f"{date_stamp}/{REGION}/s3/aws4_request"
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{hashlib.sha256(canonical_request.encode()).hexdigest()}"

    def sign(key, msg):
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    k_date = sign(f"AWS4{SECRET_KEY}".encode(), date_stamp)
    k_region = sign(k_date, REGION)
    k_service = sign(k_region, "s3")
    k_signing = sign(k_service, "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

    headers["Authorization"] = f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}"
    return headers

def request(method, path, data=None, query=""):
    payload = data if isinstance(data, bytes) else (data.encode() if data else b"")
    headers = sign_request(method, path, query, {}, payload)

    url = f"http://{HOST}{path}"
    if query:
        url += f"?{query}"

    req = urllib.request.Request(url, data=payload if payload else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except urllib.error.URLError as e:
        return 0, f"Connection failed: {e.reason}"

def test(name, expected_status, actual_status, body=""):
    status = "PASS" if actual_status == expected_status else "FAIL"
    print(f"  [{status}] {name}: {actual_status} (expected {expected_status})")
    if status == "FAIL" and body:
        print(f"        Response: {body[:100]}")
    return status == "PASS"

def run_tests():
    print("=" * 60)
    print("zs3 Test Suite")
    print("=" * 60)
    passed = 0
    failed = 0

    # Test 1: List buckets (empty)
    print("\n[Bucket Operations]")
    status, body = request("GET", "/")
    if test("List buckets (empty)", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test 2: Create bucket
    status, body = request("PUT", "/testbucket")
    if test("Create bucket", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test 3: Create bucket again (idempotent)
    status, body = request("PUT", "/testbucket")
    if test("Create bucket (idempotent)", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test 4: List buckets (should have one)
    status, body = request("GET", "/")
    if test("List buckets (has testbucket)", 200, status, body) and "testbucket" in body:
        passed += 1
    else:
        failed += 1

    # Test 5: Invalid bucket name
    status, body = request("PUT", "/ab")  # too short
    if test("Invalid bucket name (too short)", 400, status, body):
        passed += 1
    else:
        failed += 1

    # Test: Head bucket (exists)
    status, body = request("HEAD", "/testbucket")
    if test("Head bucket (exists)", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test: Head bucket (not exists)
    status, body = request("HEAD", "/nonexistentbucket")
    if test("Head bucket (not exists)", 404, status, body):
        passed += 1
    else:
        failed += 1

    # Object operations
    print("\n[Object Operations]")

    # Test 6: Put object
    status, body = request("PUT", "/testbucket/hello.txt", "Hello, World!")
    if test("Put object", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test 7: Get object
    status, body = request("GET", "/testbucket/hello.txt")
    if test("Get object", 200, status, body) and body == "Hello, World!":
        passed += 1
    else:
        failed += 1
        print(f"        Got: {body}")

    # Test 8: Head object
    status, body = request("HEAD", "/testbucket/hello.txt")
    if test("Head object", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test 9: Get non-existent object
    status, body = request("GET", "/testbucket/nonexistent.txt")
    if test("Get non-existent object", 404, status, body):
        passed += 1
    else:
        failed += 1

    # Test 10: Put nested object
    status, body = request("PUT", "/testbucket/folder/nested.txt", "Nested content")
    if test("Put nested object", 200, status, body):
        passed += 1
    else:
        failed += 1

    # Test 11: Get nested object
    status, body = request("GET", "/testbucket/folder/nested.txt")
    if test("Get nested object", 200, status, body) and body == "Nested content":
        passed += 1
    else:
        failed += 1

    # Test 12: Put binary data
    binary_data = bytes(range(256))
    status, body = request("PUT", "/testbucket/binary.bin", binary_data)
    if test("Put binary data", 200, status, body):
        passed += 1
    else:
        failed += 1

    # List operations
    print("\n[List Operations]")

    # Test 13: List objects
    status, body = request("GET", "/testbucket", query="list-type=2")
    if test("List objects", 200, status, body) and "hello.txt" in body:
        passed += 1
    else:
        failed += 1

    # Test 14: List with prefix
    status, body = request("GET", "/testbucket", query="list-type=2&prefix=folder/")
    if test("List with prefix", 200, status, body) and "nested.txt" in body:
        passed += 1
    else:
        failed += 1

    # Test 15: List with delimiter
    status, body = request("GET", "/testbucket", query="list-type=2&delimiter=/")
    if test("List with delimiter", 200, status, body) and "CommonPrefixes" in body:
        passed += 1
    else:
        failed += 1

    # Range requests
    print("\n[Range Requests]")

    # Test 16: Range request
    headers = sign_request("GET", "/testbucket/hello.txt", "", {"Range": "bytes=0-4"}, b"")
    req = urllib.request.Request(f"http://{HOST}/testbucket/hello.txt", headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req) as resp:
            status = resp.status
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        status = e.code
        body = e.read().decode()
    if test("Range request (bytes=0-4)", 206, status, body) and body == "Hello":
        passed += 1
    else:
        failed += 1
        print(f"        Got: {body}")

    # Batch Operations
    print("\n[Batch Operations]")

    # Create files for batch delete
    request("PUT", "/testbucket/batch1.txt", "batch1")
    request("PUT", "/testbucket/batch2.txt", "batch2")
    request("PUT", "/testbucket/batch3.txt", "batch3")

    # Test: DeleteObjects batch
    delete_xml = '<Delete><Object><Key>batch1.txt</Key></Object><Object><Key>batch2.txt</Key></Object><Object><Key>batch3.txt</Key></Object></Delete>'
    status, body = request("POST", "/testbucket", delete_xml, query="delete")
    if test("DeleteObjects batch", 200, status, body) and "batch1.txt" in body and "batch2.txt" in body:
        passed += 1
    else:
        failed += 1

    # Verify files are deleted
    status, body = request("GET", "/testbucket/batch1.txt")
    if test("Verify batch delete (file gone)", 404, status, body):
        passed += 1
    else:
        failed += 1

    # Cleanup
    print("\n[Cleanup]")

    # Delete objects
    status, body = request("DELETE", "/testbucket/hello.txt")
    if test("Delete object", 204, status, body):
        passed += 1
    else:
        failed += 1

    status, body = request("DELETE", "/testbucket/folder/nested.txt")
    if test("Delete nested object", 204, status, body):
        passed += 1
    else:
        failed += 1

    status, body = request("DELETE", "/testbucket/binary.bin")
    if test("Delete binary object", 204, status, body):
        passed += 1
    else:
        failed += 1

    # Delete bucket (may have leftover folder/ dir from nested object)
    # First, list and delete any remaining objects
    status, body = request("GET", "/testbucket", query="list-type=2")
    if "<Key>" in body:
        import re
        keys = re.findall(r"<Key>([^<]+)</Key>", body)
        for key in keys:
            request("DELETE", f"/testbucket/{key}")
            print(f"  [INFO] Cleaned up leftover: {key}")

    # Delete bucket
    status, body = request("DELETE", "/testbucket")
    if test("Delete bucket", 204, status, body):
        passed += 1
    else:
        failed += 1

    # Summary
    print("\n" + "=" * 60)
    total = passed + failed
    print(f"Results: {passed}/{total} tests passed")
    if failed == 0:
        print("All tests passed!")
    else:
        print(f"{failed} tests failed")
    print("=" * 60)

    return failed == 0

if __name__ == "__main__":
    import sys
    success = run_tests()
    sys.exit(0 if success else 1)
