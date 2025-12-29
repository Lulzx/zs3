#!/usr/bin/env python3
"""Benchmark S3-compatible servers"""
import hashlib
import hmac
import time
import statistics
from datetime import datetime, timezone
import urllib.request
import urllib.error
import argparse
import json

def sign_request(method, path, host, access_key, secret_key, payload=b"", query=""):
    t = datetime.now(timezone.utc)
    amz_date = t.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = t.strftime("%Y%m%d")
    region = "us-east-1"

    payload_hash = hashlib.sha256(payload).hexdigest()
    headers = {
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        "host": host,
    }

    signed_headers = ";".join(sorted(headers.keys()))
    canonical_headers = "".join(f"{k}:{v}\n" for k, v in sorted(headers.items()))
    # Sort query string params
    canonical_query = "&".join(sorted(query.split("&"))) if query else ""
    canonical_request = f"{method}\n{path}\n{canonical_query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"

    credential_scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{hashlib.sha256(canonical_request.encode()).hexdigest()}"

    def sign(key, msg):
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    k_date = sign(f"AWS4{secret_key}".encode(), date_stamp)
    k_region = sign(k_date, region)
    k_service = sign(k_region, "s3")
    k_signing = sign(k_service, "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

    headers["Authorization"] = f"AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}"
    return headers

def request(method, url, host, access_key, secret_key, data=None):
    # Extract path and query from URL
    url_path = url.split("://", 1)[1].split("/", 1)[1] if "/" in url.split("://", 1)[1] else ""
    if "?" in url_path:
        path, query = "/" + url_path.split("?")[0], url_path.split("?")[1]
    else:
        path, query = "/" + url_path, ""
    payload = data if data else b""
    headers = sign_request(method, path, host, access_key, secret_key, payload, query)

    req = urllib.request.Request(url, data=payload if payload else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()

def benchmark(name, endpoint, access_key, secret_key, iterations=100):
    host = endpoint.replace("http://", "").replace("https://", "")
    bucket = "benchbucket"
    results = {
        "create_bucket": [],
        "put_1kb": [],
        "put_4kb": [],
        "put_64kb": [],
        "put_1mb": [],
        "get_1kb": [],
        "get_4kb": [],
        "get_64kb": [],
        "get_1mb": [],
        "list": [],
        "delete": [],
    }

    # Data payloads
    data_1kb = b"x" * 1024
    data_4kb = b"x" * 4096
    data_64kb = b"x" * 65536
    data_1mb = b"x" * 1048576

    print(f"\n{'='*60}")
    print(f"Benchmarking: {name}")
    print(f"Endpoint: {endpoint}")
    print(f"Iterations: {iterations}")
    print(f"{'='*60}")

    # Create bucket
    start = time.perf_counter()
    status, _ = request("PUT", f"{endpoint}/{bucket}", host, access_key, secret_key)
    results["create_bucket"].append(time.perf_counter() - start)
    if status not in (200, 409):
        print(f"Failed to create bucket: {status}")
        return None

    # Warmup
    for i in range(5):
        request("PUT", f"{endpoint}/{bucket}/warmup{i}", host, access_key, secret_key, data_1kb)
        request("GET", f"{endpoint}/{bucket}/warmup{i}", host, access_key, secret_key)
        request("DELETE", f"{endpoint}/{bucket}/warmup{i}", host, access_key, secret_key)

    # PUT benchmarks
    for size_name, data in [("1kb", data_1kb), ("4kb", data_4kb), ("64kb", data_64kb), ("1mb", data_1mb)]:
        print(f"  PUT {size_name}...", end=" ", flush=True)
        for i in range(iterations):
            start = time.perf_counter()
            status, _ = request("PUT", f"{endpoint}/{bucket}/bench_{size_name}_{i}", host, access_key, secret_key, data)
            elapsed = time.perf_counter() - start
            if status == 200:
                results[f"put_{size_name}"].append(elapsed)
        print(f"{len(results[f'put_{size_name}'])} ok")

    # GET benchmarks
    for size_name, data in [("1kb", data_1kb), ("4kb", data_4kb), ("64kb", data_64kb), ("1mb", data_1mb)]:
        print(f"  GET {size_name}...", end=" ", flush=True)
        for i in range(iterations):
            start = time.perf_counter()
            status, body = request("GET", f"{endpoint}/{bucket}/bench_{size_name}_{i}", host, access_key, secret_key)
            elapsed = time.perf_counter() - start
            if status == 200 and len(body) == len(data):
                results[f"get_{size_name}"].append(elapsed)
        print(f"{len(results[f'get_{size_name}'])} ok")

    # LIST benchmark
    print(f"  LIST...", end=" ", flush=True)
    for i in range(iterations):
        start = time.perf_counter()
        status, _ = request("GET", f"{endpoint}/{bucket}?list-type=2", host, access_key, secret_key)
        elapsed = time.perf_counter() - start
        if status == 200:
            results["list"].append(elapsed)
    print(f"{len(results['list'])} ok")

    # DELETE benchmark
    print(f"  DELETE...", end=" ", flush=True)
    for size_name in ["1kb", "4kb", "64kb", "1mb"]:
        for i in range(iterations):
            start = time.perf_counter()
            status, _ = request("DELETE", f"{endpoint}/{bucket}/bench_{size_name}_{i}", host, access_key, secret_key)
            elapsed = time.perf_counter() - start
            if status == 204:
                results["delete"].append(elapsed)
    print(f"{len(results['delete'])} ok")

    # Cleanup
    request("DELETE", f"{endpoint}/{bucket}", host, access_key, secret_key)

    return results

def print_results(results, name):
    print(f"\n{'='*60}")
    print(f"Results: {name}")
    print(f"{'='*60}")
    print(f"{'Operation':<15} {'Mean':>10} {'Median':>10} {'P99':>10} {'Ops/sec':>10}")
    print("-" * 60)

    for op, times in results.items():
        if times:
            mean = statistics.mean(times) * 1000
            median = statistics.median(times) * 1000
            p99 = sorted(times)[int(len(times) * 0.99)] * 1000 if len(times) > 10 else max(times) * 1000
            ops_sec = len(times) / sum(times)
            print(f"{op:<15} {mean:>9.2f}ms {median:>9.2f}ms {p99:>9.2f}ms {ops_sec:>10.1f}")

def main():
    parser = argparse.ArgumentParser(description="Benchmark S3-compatible servers")
    parser.add_argument("--zs3", default="http://localhost:9000", help="zs3 endpoint")
    parser.add_argument("--rustfs", default="http://localhost:9001", help="RustFS endpoint")
    parser.add_argument("--access-key", default="minioadmin", help="Access key")
    parser.add_argument("--secret-key", default="minioadmin", help="Secret key")
    parser.add_argument("--iterations", type=int, default=100, help="Iterations per test")
    parser.add_argument("--only", choices=["zs3", "rustfs", "both"], default="both", help="Which server to benchmark")
    args = parser.parse_args()

    all_results = {}

    if args.only in ("zs3", "both"):
        try:
            results = benchmark("zs3", args.zs3, args.access_key, args.secret_key, args.iterations)
            if results:
                all_results["zs3"] = results
                print_results(results, "zs3")
        except Exception as e:
            print(f"zs3 benchmark failed: {e}")

    if args.only in ("rustfs", "both"):
        try:
            results = benchmark("RustFS", args.rustfs, args.access_key, args.secret_key, args.iterations)
            if results:
                all_results["rustfs"] = results
                print_results(results, "RustFS")
        except Exception as e:
            print(f"RustFS benchmark failed: {e}")

    if len(all_results) == 2:
        print(f"\n{'='*60}")
        print("Comparison (zs3 vs RustFS)")
        print(f"{'='*60}")
        print(f"{'Operation':<15} {'zs3':>12} {'RustFS':>12} {'Speedup':>10}")
        print("-" * 60)
        for op in all_results["zs3"]:
            if all_results["zs3"][op] and all_results["rustfs"][op]:
                zs3_mean = statistics.mean(all_results["zs3"][op]) * 1000
                rustfs_mean = statistics.mean(all_results["rustfs"][op]) * 1000
                speedup = rustfs_mean / zs3_mean if zs3_mean > 0 else 0
                winner = "zs3" if speedup > 1 else "RustFS"
                print(f"{op:<15} {zs3_mean:>10.2f}ms {rustfs_mean:>10.2f}ms {speedup:>8.2f}x ({winner})")

if __name__ == "__main__":
    main()
