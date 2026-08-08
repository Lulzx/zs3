#!/usr/bin/env python3
"""Multi-node regression tests for distributed-mode metadata replication.

Covers https://github.com/Lulzx/zs3/issues/10: a PUT on one node must be
visible to LIST/GET/HEAD on every other node, deletes must propagate, and
a node that joins (or rejoins) later must sync the existing namespace.

Scenarios:
  - bucket create/delete propagation
  - PUT on one node, GET/HEAD/LIST everywhere (inline and CAS-backed objects)
  - inline/CAS threshold boundary sizes, empty objects
  - ETag consistency and range requests across nodes
  - last-write-wins overwrites, delete-then-recreate
  - multipart upload assembled on one node, readable everywhere
  - LIST with prefix/delimiter and paginated LIST on a remote node
  - late join and restart catch-up (index sync)
  - origin node death: blobs survive via replicas
  - peer-protocol input validation (unauthenticated /_zs3/ endpoints)
"""

import hashlib
import hmac
import json
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ACCESS_KEY = "minioadmin"
SECRET_KEY = "minioadmin"
REGION = "us-east-1"

INLINE_THRESHOLD = 4 * 1024  # keep in sync with main.zig


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def sign_request(host, method, path, query="", headers=None, payload=b""):
    """AWS SigV4 signing (same scheme as test_client.py)"""
    if headers is None:
        headers = {}

    t = datetime.now(timezone.utc)
    amz_date = t.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = t.strftime("%Y%m%d")

    payload_hash = hashlib.sha256(payload).hexdigest()
    headers["x-amz-date"] = amz_date
    headers["x-amz-content-sha256"] = payload_hash
    headers["host"] = host

    signed_headers = ";".join(sorted(k.lower() for k in headers))
    canonical_headers = "".join(
        f"{k.lower()}:{v}\n" for k, v in sorted(headers.items(), key=lambda x: x[0].lower())
    )

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

    headers["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    return headers


def s3(port, method, path, data=None, query="", extra_headers=None):
    """Signed S3 request; returns (status, body, headers)."""
    host = f"127.0.0.1:{port}"
    payload = data if isinstance(data, bytes) else (data.encode() if data else b"")
    headers = sign_request(host, method, path, query, {}, payload)
    if extra_headers:
        headers.update(extra_headers)

    url = f"http://{host}{path}"
    if query:
        url += f"?{query}"

    req = urllib.request.Request(url, data=payload if payload else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def raw(port, method, path, data=b""):
    """Unsigned request to a peer-protocol endpoint; returns (status, body)."""
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=data if data else None, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def wait_ready(port, timeout=10):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/_zs3/ping", timeout=1) as resp:
                return json.load(resp)
        except Exception as error:
            last_error = error
            time.sleep(0.1)
    raise AssertionError(f"node on port {port} did not become ready: {last_error}")


CHECKS = {"passed": 0, "failed": 0}


def check(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"  [{status}] {name}" + (f": {detail}" if not ok and detail else ""))
    CHECKS["passed" if ok else "failed"] += 1


def retry(fn, timeout=5):
    """Retry a boolean check briefly to absorb propagation latency."""
    deadline = time.monotonic() + timeout
    while True:
        if fn():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.2)


def list_keys(port, bucket, query_extra=""):
    """Paginate a full LIST and return all keys."""
    keys = []
    token = None
    for _ in range(100):
        query = "list-type=2"
        if query_extra:
            query += "&" + query_extra
        if token:
            query += "&continuation-token=" + urllib.parse.quote(token, safe="")
        status, body, _ = s3(port, "GET", f"/{bucket}", query=query)
        if status != 200:
            return None
        text = body.decode()
        keys.extend(re.findall(r"<Key>([^<]*)</Key>", text))
        if "<IsTruncated>true</IsTruncated>" not in text:
            return keys
        match = re.search(r"<NextContinuationToken>([^<]*)</NextContinuationToken>", text)
        if not match:
            return None
        token = match.group(1)
    return None


class Cluster:
    def __init__(self, executable, root):
        self.executable = executable
        self.root = root
        self.ports = {}
        self.processes = {}
        self.logs = {}

    def start(self, name, bootstrap=None, port=None):
        if port is None:
            port = self.ports.get(name, unused_port())
        self.ports[name] = port
        log = (self.root / f"{name}-{int(time.time() * 1000)}.log").open("w+")
        argv = [
            self.executable,
            "--distributed",
            f"--port={port}",
            f"--data-dir={self.root / name}",
        ]
        if bootstrap:
            argv.append("--bootstrap=" + ",".join(f"localhost:{self.ports[b]}" for b in bootstrap))
        self.processes[name] = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        self.logs.setdefault(name, []).append(log)
        return wait_ready(port)

    def stop(self, name):
        process = self.processes.get(name)
        if process is None or process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    def port(self, name):
        return self.ports[name]

    def alive(self, name):
        process = self.processes.get(name)
        return process is not None and process.poll() is None

    def stop_all(self):
        for name in list(self.processes):
            self.stop(name)
        for logs in self.logs.values():
            for log in logs:
                log.close()

    def dump_logs(self):
        for name, logs in self.logs.items():
            for log in logs:
                log.seek(0)
                sys.stderr.write(f"\nnode {name.upper()} log ({log.name}):\n{log.read()}\n")


def scenario_bucket_propagation(c):
    print("\n[bucket propagation]")
    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket")
    check("create bucket on A", status == 200, f"status {status}")
    for node in ("b", "c"):
        ok = retry(lambda n=node: s3(c.port(n), "HEAD", "/demo-bucket")[0] == 200)
        check(f"HeadBucket on {node.upper()}", ok)
    for node in ("a", "b", "c"):
        status, body, _ = s3(c.port(node), "GET", "/")
        check(f"ListBuckets on {node.upper()} shows bucket", status == 200 and b"demo-bucket" in body,
              f"status {status}")


def scenario_basic_replication(c, small_body, large_body):
    print("\n[PUT on A, read everywhere]")
    status, _, put_headers = s3(c.port("a"), "PUT", "/demo-bucket/hello.txt", small_body)
    check("PUT small object on A", status == 200, f"status {status}")
    put_etag = put_headers.get("ETag")
    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket/big/blob.bin", large_body)
    check("PUT large object on A", status == 200, f"status {status}")

    for node in ("a", "b", "c"):
        status, body, get_headers = s3(c.port(node), "GET", "/demo-bucket/hello.txt")
        check(f"GET small on {node.upper()}", status == 200 and body == small_body,
              f"status {status}, len {len(body)}")
        check(f"ETag consistent on {node.upper()}", get_headers.get("ETag") == put_etag,
              f"{get_headers.get('ETag')} != {put_etag}")
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/big/blob.bin")
        check(f"GET large on {node.upper()}", status == 200 and body == large_body,
              f"status {status}, len {len(body)}")
        status, _, head_headers = s3(c.port(node), "HEAD", "/demo-bucket/hello.txt")
        check(f"HEAD small on {node.upper()}", status == 200
              and head_headers.get("Content-Length") == str(len(small_body)),
              f"status {status}, len {head_headers.get('Content-Length')}")
        keys = list_keys(c.port(node), "demo-bucket")
        check(f"LIST on {node.upper()}", keys is not None
              and "hello.txt" in keys and "big/blob.bin" in keys, f"keys {keys}")

    print("\n[PUT on B, read on A and C]")
    status, _, _ = s3(c.port("b"), "PUT", "/demo-bucket/from-b.txt", b"written on B")
    check("PUT on B", status == 200, f"status {status}")
    for node in ("a", "c"):
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/from-b.txt")
        check(f"GET from-b.txt on {node.upper()}", status == 200 and body == b"written on B",
              f"status {status}")


def scenario_sizes(c):
    print("\n[size edge cases]")
    cases = {
        "sizes/empty.bin": b"",
        "sizes/one.bin": b"x",
        "sizes/inline-max.bin": b"i" * INLINE_THRESHOLD,
        "sizes/cas-min.bin": b"c" * (INLINE_THRESHOLD + 1),
    }
    for i, (key, body) in enumerate(cases.items()):
        origin = ("a", "b", "c")[i % 3]
        status, _, _ = s3(c.port(origin), "PUT", f"/demo-bucket/{key}", body)
        check(f"PUT {key} on {origin.upper()}", status == 200, f"status {status}")
    for key, body in cases.items():
        for node in ("a", "b", "c"):
            status, got, _ = s3(c.port(node), "GET", f"/demo-bucket/{key}")
            check(f"GET {key} on {node.upper()}", status == 200 and got == body,
                  f"status {status}, len {len(got)}")


def scenario_special_keys(c):
    print("\n[key edge cases]")
    key = "spec-_.~chars/deep/nested/dir/structure/file-v1.2_final~.txt"
    body = b"special key content"
    status, _, _ = s3(c.port("c"), "PUT", f"/demo-bucket/{key}", body)
    check("PUT deep special key on C", status == 200, f"status {status}")
    for node in ("a", "b"):
        status, got, _ = s3(c.port(node), "GET", f"/demo-bucket/{key}")
        check(f"GET deep special key on {node.upper()}", status == 200 and got == body,
              f"status {status}")


def scenario_range_requests(c, large_body):
    print("\n[range requests across nodes]")
    for node in ("b", "c"):
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/big/blob.bin",
                             extra_headers={"Range": "bytes=100-199"})
        check(f"range 100-199 on {node.upper()}", status == 206 and body == large_body[100:200],
              f"status {status}, len {len(body)}")
    status, body, _ = s3(c.port("b"), "GET", "/demo-bucket/big/blob.bin",
                         extra_headers={"Range": "bytes=-50"})
    check("suffix range on B", status == 206 and body == large_body[-50:],
          f"status {status}, len {len(body)}")


def scenario_overwrite_lww(c):
    print("\n[last-write-wins overwrite]")
    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket/versioned.txt", b"version 1")
    check("PUT v1 on A", status == 200, f"status {status}")
    time.sleep(1.2)  # meta timestamps have second granularity
    status, _, _ = s3(c.port("b"), "PUT", "/demo-bucket/versioned.txt", b"version 2 wins")
    check("PUT v2 on B", status == 200, f"status {status}")
    for node in ("a", "b", "c"):
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/versioned.txt")
        check(f"GET v2 on {node.upper()}", status == 200 and body == b"version 2 wins",
              f"status {status}, body {body[:40]}")


def scenario_delete_propagation(c):
    print("\n[DELETE on B, gone everywhere]")
    status, _, _ = s3(c.port("b"), "DELETE", "/demo-bucket/hello.txt")
    check("DELETE on B", status == 204, f"status {status}")
    for node in ("a", "c"):
        status, _, _ = s3(c.port(node), "GET", "/demo-bucket/hello.txt")
        check(f"GET deleted key on {node.upper()} -> 404", status == 404, f"status {status}")
        status, _, _ = s3(c.port(node), "HEAD", "/demo-bucket/hello.txt")
        check(f"HEAD deleted key on {node.upper()} -> 404", status == 404, f"status {status}")
        keys = list_keys(c.port(node), "demo-bucket")
        check(f"LIST on {node.upper()} omits deleted key", keys is not None and "hello.txt" not in keys)


def scenario_delete_then_recreate(c):
    print("\n[delete then recreate]")
    status, _, _ = s3(c.port("a"), "DELETE", "/demo-bucket/from-b.txt")
    check("DELETE from-b.txt on A", status == 204, f"status {status}")
    status, _, _ = s3(c.port("c"), "GET", "/demo-bucket/from-b.txt")
    check("deleted on C", status == 404, f"status {status}")
    time.sleep(1.2)  # let the recreate timestamp beat the tombstone
    status, _, _ = s3(c.port("c"), "PUT", "/demo-bucket/from-b.txt", b"recreated on C")
    check("recreate on C", status == 200, f"status {status}")
    for node in ("a", "b"):
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/from-b.txt")
        check(f"GET recreated on {node.upper()}", status == 200 and body == b"recreated on C",
              f"status {status}, body {body[:40]}")


def scenario_multipart(c):
    print("\n[multipart upload cross-node]")
    part1 = b"P" * (64 * 1024)
    part2 = b"Q" * (64 * 1024)
    full = part1 + part2

    status, body, _ = s3(c.port("a"), "POST", "/demo-bucket/multi/assembled.bin", query="uploads")
    match = re.search(r"<UploadId>([^<]*)</UploadId>", body.decode()) if status == 200 else None
    check("initiate multipart on A", match is not None, f"status {status}")
    if match is None:
        return
    upload_id = match.group(1)

    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket/multi/assembled.bin", part1,
                      query=f"partNumber=1&uploadId={upload_id}")
    check("upload part 1", status == 200, f"status {status}")
    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket/multi/assembled.bin", part2,
                      query=f"partNumber=2&uploadId={upload_id}")
    check("upload part 2", status == 200, f"status {status}")

    complete_xml = (
        "<CompleteMultipartUpload>"
        "<Part><PartNumber>1</PartNumber></Part>"
        "<Part><PartNumber>2</PartNumber></Part>"
        "</CompleteMultipartUpload>"
    )
    status, _, _ = s3(c.port("a"), "POST", "/demo-bucket/multi/assembled.bin", complete_xml,
                      query=f"uploadId={upload_id}")
    check("complete multipart on A", status == 200, f"status {status}")

    for node in ("b", "c"):
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/multi/assembled.bin")
        check(f"GET assembled on {node.upper()}", status == 200 and body == full,
              f"status {status}, len {len(body)}")


def scenario_list_features(c):
    print("\n[LIST prefix/delimiter/pagination on remote nodes]")
    for i in range(25):
        origin = ("a", "b", "c")[i % 3]
        status, _, _ = s3(c.port(origin), "PUT", f"/demo-bucket/bulk/k{i:02}", f"item {i}".encode())
        if status != 200:
            check(f"PUT bulk/k{i:02}", False, f"status {status}")
            return
    check("PUT 25 bulk keys across A/B/C", True)

    keys = list_keys(c.port("c"), "demo-bucket", query_extra="prefix=bulk/&max-keys=7")
    expected = [f"bulk/k{i:02}" for i in range(25)]
    check("paginated LIST (max-keys=7) on C", keys == expected, f"got {keys}")

    status, body, _ = s3(c.port("b"), "GET", "/demo-bucket",
                         query="list-type=2&prefix=big/&delimiter=/")
    text = body.decode() if status == 200 else ""
    check("LIST prefix=big/ on B", status == 200 and "big/blob.bin" in text, f"status {status}")

    status, body, _ = s3(c.port("b"), "GET", "/demo-bucket", query="list-type=2&delimiter=/")
    text = body.decode() if status == 200 else ""
    check("LIST delimiter=/ on B groups prefixes", status == 200
          and "<Prefix>bulk/</Prefix>" in text and "<Prefix>big/</Prefix>" in text
          and "bulk/k00" not in text,
          f"status {status}, body {text[:300]}")


def scenario_late_join(c, large_body):
    print("\n[late join: node D syncs existing namespace]")
    c.start("d", bootstrap=["a"])
    keys = list_keys(c.port("d"), "demo-bucket")
    check("LIST on D after join", keys is not None
          and "big/blob.bin" in keys and "from-b.txt" in keys and "hello.txt" not in keys,
          f"keys {keys}")
    status, body, _ = s3(c.port("d"), "GET", "/demo-bucket/big/blob.bin")
    check("GET large on D", status == 200 and body == large_body,
          f"status {status}, len {len(body)}")
    status, body, _ = s3(c.port("d"), "GET", "/demo-bucket/big/blob.bin",
                         extra_headers={"Range": "bytes=0-9"})
    check("range GET on D after blob cache", status == 206 and body == large_body[:10],
          f"status {status}")
    status, _, _ = s3(c.port("d"), "GET", "/demo-bucket/hello.txt")
    check("deleted key still 404 on D", status == 404, f"status {status}")
    status, body, _ = s3(c.port("d"), "GET", "/demo-bucket/versioned.txt")
    check("LWW winner visible on D", status == 200 and body == b"version 2 wins", f"status {status}")


def scenario_restart_catchup(c):
    print("\n[restart catch-up: D misses a PUT while down]")
    c.stop("d")
    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket/while-d-down.txt", b"missed push")
    check("PUT on A while D is down", status == 200, f"status {status}")
    c.start("d", bootstrap=["a"])
    status, body, _ = s3(c.port("d"), "GET", "/demo-bucket/while-d-down.txt")
    check("GET missed key on D after restart", status == 200 and body == b"missed push",
          f"status {status}")


def scenario_bucket_lifecycle(c):
    print("\n[second bucket lifecycle]")
    status, _, _ = s3(c.port("c"), "PUT", "/short-lived")
    check("create bucket on C", status == 200, f"status {status}")
    status, _, _ = s3(c.port("c"), "PUT", "/short-lived/note.txt", b"temporary")
    check("PUT into it on C", status == 200, f"status {status}")
    status, body, _ = s3(c.port("a"), "GET", "/short-lived/note.txt")
    check("GET from it on A", status == 200 and body == b"temporary", f"status {status}")

    status, _, _ = s3(c.port("a"), "DELETE", "/short-lived/note.txt")
    check("DELETE object on A", status == 204, f"status {status}")
    status, _, _ = s3(c.port("a"), "DELETE", "/short-lived")
    check("DeleteBucket on A", status == 204, f"status {status}")
    for node in ("b", "c"):
        ok = retry(lambda n=node: s3(c.port(n), "HEAD", "/short-lived")[0] == 404)
        check(f"bucket gone on {node.upper()}", ok)


def scenario_origin_death(c, replicated_body):
    print("\n[origin death: blob survives via replicas]")
    status, _, _ = s3(c.port("a"), "PUT", "/demo-bucket/final/replicated.bin", replicated_body)
    check("PUT replicated blob on A", status == 200, f"status {status}")
    c.stop("a")
    check("node A stopped", not c.alive("a"))
    for node in ("b", "c", "d"):
        status, body, _ = s3(c.port(node), "GET", "/demo-bucket/final/replicated.bin")
        check(f"GET after origin death on {node.upper()}", status == 200 and body == replicated_body,
              f"status {status}, len {len(body)}")


def scenario_peer_protocol_validation(c):
    print("\n[peer protocol validation]")
    port = c.port("b")
    valid_meta = b"a" * 40 + b"\n5\n1700000000\n0\nhello"

    status, _ = raw(port, "POST", "/_zs3/meta", b"..\nkey.txt\n" + valid_meta)
    check("meta rejects traversal bucket", status == 400, f"status {status}")
    status, _ = raw(port, "POST", "/_zs3/meta", b"demo-bucket\n../../evil\n" + valid_meta)
    check("meta rejects traversal key", status == 400, f"status {status}")
    status, _ = raw(port, "POST", "/_zs3/meta", b"demo-bucket\nok.txt\ngarbage-content")
    check("meta rejects malformed entry", status == 400, f"status {status}")
    status, _ = raw(port, "POST", "/_zs3/meta", b"no-newlines-at-all")
    check("meta rejects missing framing", status == 400, f"status {status}")
    status, _ = raw(port, "GET", "/_zs3/meta")
    check("meta rejects GET", status == 405, f"status {status}")

    status, _ = raw(port, "POST", "/_zs3/meta_get", b"demo-bucket\nno-such-key-anywhere")
    check("meta_get unknown key -> 404", status == 404, f"status {status}")
    status, _ = raw(port, "POST", "/_zs3/meta_get", b"..\nkey")
    check("meta_get rejects bad bucket", status == 400, f"status {status}")

    status, body = raw(port, "GET", "/_zs3/index")
    check("index dump served", status == 200 and b"demo-bucket" in body, f"status {status}")

    status, _ = raw(port, "POST", "/_zs3/bucket", b"ab")
    check("bucket rejects invalid name", status == 400, f"status {status}")
    status, _ = raw(port, "POST", "/_zs3/bucket_delete", b"..")
    check("bucket_delete rejects invalid name", status == 400, f"status {status}")

    status, _ = raw(port, "POST", "/_zs3/announce", b"tooshort\nabc")
    check("announce rejects malformed body", status == 400, f"status {status}")
    status, _ = raw(port, "GET", "/_zs3/blob/nothex")
    check("blob rejects invalid hash", status == 400, f"status {status}")
    status, _ = raw(port, "GET", "/_zs3/nonexistent")
    check("unknown peer endpoint -> 404", status == 404, f"status {status}")


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zs3").resolve()
    if not executable.is_file():
        raise SystemExit(f"zs3 executable not found: {executable}")

    small_body = b"hello from node A\n"
    large_body = bytes(range(256)) * 512  # 128 KiB, above INLINE_THRESHOLD
    replicated_body = b"R" * (32 * 1024)

    with tempfile.TemporaryDirectory(prefix="zs3-replication-test-") as temp_dir:
        cluster = Cluster(executable, Path(temp_dir))
        try:
            cluster.start("a")
            cluster.start("b", bootstrap=["a"])
            cluster.start("c", bootstrap=["a", "b"])

            scenario_bucket_propagation(cluster)
            scenario_basic_replication(cluster, small_body, large_body)
            scenario_sizes(cluster)
            scenario_special_keys(cluster)
            scenario_range_requests(cluster, large_body)
            scenario_overwrite_lww(cluster)
            scenario_delete_propagation(cluster)
            scenario_delete_then_recreate(cluster)
            scenario_multipart(cluster)
            scenario_list_features(cluster)
            scenario_late_join(cluster, large_body)
            scenario_restart_catchup(cluster)
            scenario_bucket_lifecycle(cluster)
            scenario_peer_protocol_validation(cluster)
            scenario_origin_death(cluster, replicated_body)  # kills node A; keep last
        except Exception:
            cluster.dump_logs()
            raise
        finally:
            cluster.stop_all()

    print(f"\n{CHECKS['passed']} passed, {CHECKS['failed']} failed")
    if CHECKS["failed"]:
        raise SystemExit(1)
    print("distributed replication test passed")


if __name__ == "__main__":
    main()
