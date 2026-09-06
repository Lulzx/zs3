#!/usr/bin/env python3
"""Foreign-tree test: point zs3 at a directory it did not create.

Builds a tree with plain shell tools (mkdir/cp/printf), starts zs3 with
--data-dir pointing at it, and verifies the positioning claim: the
filesystem is the source of truth and zs3 is a protocol adapter.

Covers: ListBuckets (valid names only), LIST/GET/HEAD/range on files zs3
never wrote, extension-sniffed Content-Types, ETag == local md5sum, and
`rclone check` (which compares MD5s) against the foreign tree.
"""
import hashlib
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import boto3
from botocore.config import Config

ZS3 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zig-out", "bin", "zs3")
PORT = 9129
ENDPOINT = f"http://localhost:{PORT}"

fails = []


def check(name, cond, extra=""):
    print(("  [PASS] " if cond else "  [FAIL] ") + name + (f" ({extra})" if extra and not cond else ""))
    if not cond:
        fails.append(name)


def wait_for_port(port, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("localhost", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def main():
    tree = tempfile.mkdtemp(prefix="zs3-foreign.")
    # A valid bucket, built with shell tools only.
    bucket_dir = os.path.join(tree, "photos-2024")
    os.makedirs(os.path.join(bucket_dir, "raw", "sub"))
    files = {
        "index.html": b"<html><body>hi</body></html>",
        "data.json": b'{"a": 1}',
        "raw/img001.bin": bytes(range(256)) * 64,
        "raw/sub/notes.txt": b"line1\nline2\n",
        "noext": b"no extension here",
        ".hidden": b"dotfile",
        "empty.txt": b"",
        "sp ace.txt": b"spaces in names",
    }
    for rel, content in files.items():
        with open(os.path.join(bucket_dir, rel), "wb") as f:
            f.write(content)
    # An invalid bucket name: must be hidden from ListBuckets, rejected on use.
    os.makedirs(os.path.join(tree, "Bad_Name"), exist_ok=True)
    with open(os.path.join(tree, "Bad_Name", "x.txt"), "wb") as f:
        f.write(b"nope")

    server = subprocess.Popen(
        [ZS3, f"--data-dir={tree}", f"--port={PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        if not wait_for_port(PORT):
            print("server did not start");
            return 1
        s3 = boto3.client("s3", endpoint_url=ENDPOINT,
            aws_access_key_id="minioadmin", aws_secret_access_key="minioadmin",
            config=Config(s3={"addressing_style": "path"}))

        buckets = [b["Name"] for b in s3.list_buckets()["Buckets"]]
        check("ListBuckets shows foreign bucket", "photos-2024" in buckets, str(buckets))
        check("ListBuckets hides invalid bucket dir", "Bad_Name" not in buckets, str(buckets))
        try:
            s3.list_objects_v2(Bucket="Bad_Name")
            check("invalid bucket rejected", False)
        except Exception as e:
            check("invalid bucket rejected", "InvalidBucketName" in str(e), str(e))

        listed = sorted(o["Key"] for o in s3.list_objects_v2(Bucket="photos-2024").get("Contents", []))
        for rel in files:
            check(f"LIST contains {rel}", rel in listed, str(listed))

        for rel, content in files.items():
            body = s3.get_object(Bucket="photos-2024", Key=rel)["Body"].read()
            check(f"GET {rel}", body == content)
            head = s3.head_object(Bucket="photos-2024", Key=rel)
            check(f"HEAD size {rel}", head["ContentLength"] == len(content))
            check(f"ETag == md5sum {rel}",
                head["ETag"].strip('"') == hashlib.md5(content).hexdigest(), head["ETag"])

        check("sniffed text/html",
            s3.head_object(Bucket="photos-2024", Key="index.html")["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "text/html")
        check("sniffed application/json",
            s3.head_object(Bucket="photos-2024", Key="data.json")["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "application/json")
        check("sniffed text/plain",
            s3.head_object(Bucket="photos-2024", Key="raw/sub/notes.txt")["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "text/plain")
        check("unknown ext stays binary/octet-stream",
            s3.head_object(Bucket="photos-2024", Key="noext")["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "binary/octet-stream")

        # Range over a foreign binary file.
        raw = files["raw/img001.bin"]
        check("range over foreign file",
            s3.get_object(Bucket="photos-2024", Key="raw/img001.bin", Range="bytes=100-199")["Body"].read() == raw[100:200])

        # rclone sync + check: rclone compares MD5s, so this proves ETag
        # agreement against a tree zs3 did not write.
        rclone_conf = os.path.join(tree, "rclone.conf")
        subprocess.run(["rclone", "--config", rclone_conf, "config", "create", "zs3f", "s3",
            "provider", "Other", "env_auth", "false", "access_key_id", "minioadmin",
            "secret_access_key", "minioadmin", "endpoint", ENDPOINT,
            "region", "us-east-1", "force_path_style", "true", "--non-interactive"],
            check=True, capture_output=True)
        mirror = os.path.join(tree, "mirror")
        r = subprocess.run(["rclone", "--config", rclone_conf, "sync", "zs3f:photos-2024", mirror],
            capture_output=True, text=True)
        check("rclone sync from foreign tree", r.returncode == 0, r.stderr[-300:])
        r = subprocess.run(["rclone", "--config", rclone_conf, "check", "zs3f:photos-2024", mirror],
            capture_output=True, text=True)
        check("rclone check (MD5 agreement)", r.returncode == 0, r.stderr[-300:])
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        shutil.rmtree(tree, ignore_errors=True)

    print()
    if fails:
        print(f"{len(fails)} FAILURES: {fails}")
        return 1
    print("FOREIGN-TREE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
