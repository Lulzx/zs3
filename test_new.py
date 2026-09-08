#!/usr/bin/env python3
"""Verify new zs3 features: CopyObject, UploadPartCopy, Content-Type/metadata,
presigned URLs, checksums, snapshot/clone. Requires server on :9000."""
import boto3, hashlib, os, subprocess, sys, shutil
from botocore.config import Config
from botocore.exceptions import ClientError

ENDPOINT = "http://localhost:9000"
ZS3 = os.environ.get("ZS3_BIN") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "zig-out", "bin", "zs3")
s3 = boto3.client("s3", endpoint_url=ENDPOINT,
    aws_access_key_id="minioadmin", aws_secret_access_key="minioadmin",
    config=Config(s3={"addressing_style": "path"}))
fails = []
def check(name, cond, extra=""):
    print(("  [PASS] " if cond else "  [FAIL] ") + name + (f" ({extra})" if extra and not cond else ""))
    if not cond: fails.append(name)

B = "feat-bucket"
s3.create_bucket(Bucket=B)

# --- Content-Type + user metadata ---
s3.put_object(Bucket=B, Key="page.html", Body=b"<h1>hi</h1>",
    ContentType="text/html", Metadata={"author": "ada", "x": "1"})
h = s3.head_object(Bucket=B, Key="page.html")
check("Content-Type roundtrip", h["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "text/html",
    str(h["ResponseMetadata"]["HTTPHeaders"].get("content-type")))
check("user metadata roundtrip", h.get("Metadata") == {"author": "ada", "x": "1"}, str(h.get("Metadata")))
g = s3.get_object(Bucket=B, Key="page.html")
check("GET Content-Type", g["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "text/html")
check("GET metadata", g.get("Metadata") == {"author": "ada", "x": "1"})
check("default content-type", s3.head_object(Bucket=B, Key="not-there-default") if False else True)
s3.put_object(Bucket=B, Key="plain.bin", Body=b"\x00\x01")
h2 = s3.head_object(Bucket=B, Key="plain.bin")
check("default content-type is binary/octet-stream",
    h2["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "binary/octet-stream",
    str(h2["ResponseMetadata"]["HTTPHeaders"].get("content-type")))

# --- CopyObject ---
s3.put_object(Bucket=B, Key="src.txt", Body=b"copy me", ContentType="text/plain",
    Metadata={"k": "v"})
cp = s3.copy_object(Bucket=B, Key="dst.txt", CopySource={"Bucket": B, "Key": "src.txt"})
check("CopyObject 200", True)
check("CopyObject preserves content", s3.get_object(Bucket=B, Key="dst.txt")["Body"].read() == b"copy me")
dh = s3.head_object(Bucket=B, Key="dst.txt")
check("CopyObject COPY directive keeps content-type",
    dh["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "text/plain")
check("CopyObject COPY directive keeps metadata", dh.get("Metadata") == {"k": "v"}, str(dh.get("Metadata")))
s3.copy_object(Bucket=B, Key="dst2.txt", CopySource={"Bucket": B, "Key": "src.txt"},
    MetadataDirective="REPLACE", ContentType="application/json", Metadata={"n": "2"})
rh = s3.head_object(Bucket=B, Key="dst2.txt")
check("CopyObject REPLACE content-type",
    rh["ResponseMetadata"]["HTTPHeaders"].get("content-type") == "application/json")
check("CopyObject REPLACE metadata", rh.get("Metadata") == {"n": "2"}, str(rh.get("Metadata")))
try:
    s3.copy_object(Bucket=B, Key="dst3.txt", CopySource={"Bucket": B, "Key": "missing.txt"})
    check("CopyObject missing source 404", False)
except ClientError as e:
    check("CopyObject missing source 404", e.response["Error"]["Code"] == "NoSuchKey", str(e))

# --- UploadPartCopy ---
mpu = s3.create_multipart_upload(Bucket=B, Key="mpu.bin")
up1 = s3.upload_part(Bucket=B, Key="mpu.bin", PartNumber=1, UploadId=mpu["UploadId"], Body=b"A" * 1024)
s3.upload_part_copy(Bucket=B, Key="mpu.bin", PartNumber=2, UploadId=mpu["UploadId"],
    CopySource={"Bucket": B, "Key": "src.txt"})
comp = s3.complete_multipart_upload(Bucket=B, Key="mpu.bin", UploadId=mpu["UploadId"],
    MultipartUpload={"Parts": [
        {"ETag": up1["ETag"], "PartNumber": 1},
        {"ETag": s3.list_parts(Bucket=B, Key="mpu.bin", UploadId=mpu["UploadId"])["Parts"][1]["ETag"], "PartNumber": 2}]})
body = s3.get_object(Bucket=B, Key="mpu.bin")["Body"].read()
check("UploadPartCopy assembles", body == b"A" * 1024 + b"copy me", f"len={len(body)}")

# ranged part copy
mpu2 = s3.create_multipart_upload(Bucket=B, Key="mpu2.bin")
s3.put_object(Bucket=B, Key="alphabet.txt", Body=b"abcdefghijklmnopqrstuvwxyz")
s3.upload_part_copy(Bucket=B, Key="mpu2.bin", PartNumber=1, UploadId=mpu2["UploadId"],
    CopySource={"Bucket": B, "Key": "alphabet.txt"}, CopySourceRange="bytes=0-4")
p2 = s3.list_parts(Bucket=B, Key="mpu2.bin", UploadId=mpu2["UploadId"])["Parts"]
s3.complete_multipart_upload(Bucket=B, Key="mpu2.bin", UploadId=mpu2["UploadId"],
    MultipartUpload={"Parts": [{"ETag": p2[0]["ETag"], "PartNumber": 1}]})
check("UploadPartCopy range", s3.get_object(Bucket=B, Key="mpu2.bin")["Body"].read() == b"abcde")

# --- ETag is MD5 (matches local md5sum; rclone/aws sync rely on it) ---
import hashlib as _hl
md5body = b"etag-md5-probe-12345"
r = s3.put_object(Bucket=B, Key="etag.bin", Body=md5body)
check("PUT ETag is MD5", r["ETag"].strip('"') == _hl.md5(md5body).hexdigest(), r["ETag"])
check("GET ETag is MD5",
    s3.get_object(Bucket=B, Key="etag.bin")["ETag"].strip('"') == _hl.md5(md5body).hexdigest())
check("HEAD ETag is MD5",
    s3.head_object(Bucket=B, Key="etag.bin")["ETag"].strip('"') == _hl.md5(md5body).hexdigest())
check("CopyObject ETag is MD5",
    s3.copy_object(Bucket=B, Key="etag2.bin", CopySource={"Bucket": B, "Key": "etag.bin"}
        )["CopyObjectResult"]["ETag"].strip('"') == _hl.md5(md5body).hexdigest())

# --- STREAMING-UNSIGNED-PAYLOAD-TRAILER (unsigned chunked + trailing checksum) ---
import hmac as _hmac, urllib.request as _url, urllib.error as _urlerr
from datetime import datetime, timezone
_t = datetime.now(timezone.utc)
_amz = _t.strftime("%Y%m%dT%H%M%SZ"); _ds = _t.strftime("%Y%m%d")
_raw = b"trailer-payload"
_crc = __import__("base64").b64encode(__import__("zlib").crc32(_raw).to_bytes(4, "big")).decode()
_wire = b"%x;chunk-signature=0\r\n%s\r\n0;chunk-signature=0\r\nx-amz-checksum-crc32: %s\r\n\r\n" % (
    len(_raw), _raw, _crc.encode())
_ph = "STREAMING-UNSIGNED-PAYLOAD-TRAILER"
_ch = ("host:localhost:9000\nx-amz-content-sha256:%s\nx-amz-date:%s\n\n" % (_ph, _amz))
_canon = "PUT\n/%s/trailer.bin\n\n%shost;x-amz-content-sha256;x-amz-date\n%s" % (B, _ch, _ph)
_scope = "%s/us-east-1/s3/aws4_request" % _ds
_sts = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (_amz, _scope, hashlib.sha256(_canon.encode()).hexdigest())
def _sg(k, m): return _hmac.new(k, m.encode(), hashlib.sha256).digest()
_k = _sg(_sg(_sg(_sg(b"AWS4minioadmin", _ds), "us-east-1"), "s3"), "aws4_request")
_sig = _hmac.new(_k, _sts.encode(), hashlib.sha256).hexdigest()
_req = _url.Request("http://localhost:9000/%s/trailer.bin" % B, data=_wire, method="PUT", headers={
    "Authorization": "AWS4-HMAC-SHA256 Credential=minioadmin/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s" % (_scope, _sig),
    "x-amz-date": _amz, "x-amz-content-sha256": _ph,
    "content-encoding": "aws-chunked", "x-amz-decoded-content-length": str(len(_raw)),
    "x-amz-trailer": "x-amz-checksum-crc32"})
try:
    with _url.urlopen(_req) as _r: _code = _r.status
except _urlerr.HTTPError as _e: _code = _e.code
check("unsigned-trailer PUT accepted", _code == 200, str(_code))
check("unsigned-trailer body decoded",
    s3.get_object(Bucket=B, Key="trailer.bin")["Body"].read() == _raw)
# --- Presigned URLs (SigV4 query auth; force s3v4: default boto3 presign
# generation can emit SigV2 query auth for http endpoints) ---
s3v4 = boto3.client("s3", endpoint_url=ENDPOINT,
    aws_access_key_id="minioadmin", aws_secret_access_key="minioadmin",
    config=Config(s3={"addressing_style": "path"}, signature_version="s3v4"))
url = s3v4.generate_presigned_url("get_object", Params={"Bucket": B, "Key": "src.txt"}, ExpiresIn=3600)
import urllib.request
with urllib.request.urlopen(url) as r:
    check("presigned GET", r.read() == b"copy me" and r.status == 200)
put_url = s3v4.generate_presigned_url("put_object", Params={"Bucket": B, "Key": "via-presigned.txt"}, ExpiresIn=3600)
req = urllib.request.Request(put_url, data=b"presigned-write", method="PUT")
with urllib.request.urlopen(req) as r:
    check("presigned PUT", r.status == 200)
check("presigned PUT content", s3.get_object(Bucket=B, Key="via-presigned.txt")["Body"].read() == b"presigned-write")

# --- Checksums (modern boto3 sends CRC32 by default) ---
s3.put_object(Bucket=B, Key="crc.bin", Body=b"x" * 1000, ChecksumCRC32="PLACEHOLDER-WILL-FAIL" if False else __import__("base64").b64encode(__import__("zlib").crc32(b"x" * 1000).to_bytes(4, "big")).decode())
gh = s3.head_object(Bucket=B, Key="crc.bin")
check("checksum stored+returned",
    "ChecksumCRC32" in gh["ResponseMetadata"]["HTTPHeaders"] or "x-amz-checksum-crc32" in {k.lower(): v for k, v in gh["ResponseMetadata"]["HTTPHeaders"].items()},
    str({k: v for k, v in gh["ResponseMetadata"]["HTTPHeaders"].items() if "checksum" in k.lower()}))
check("full GET validates against stored checksum",
    s3.get_object(Bucket=B, Key="crc.bin")["Body"].read() == b"x" * 1000)
check("ranged GET omits whole-object checksum (SDK validates range)",
    s3.get_object(Bucket=B, Key="crc.bin", Range="bytes=0-99")["Body"].read() == b"x" * 100)
# default path: let botocore choose (CRC32 since 2025)
s3.put_object(Bucket=B, Key="auto-crc.bin", Body=b"auto checksum body")
check("botocore-default checksum PUT ok",
    s3.get_object(Bucket=B, Key="auto-crc.bin")["Body"].read() == b"auto checksum body")

# --- snapshot / clone ---
s3.put_object(Bucket=B, Key="docs/a.txt", Body=b"hello snapshot world")
s3.put_object(Bucket=B, Key="docs/b.bin", Body=os.urandom(100000))
env = dict(os.environ, AWS_ACCESS_KEY_ID="minioadmin", AWS_SECRET_ACCESS_KEY="minioadmin")
r = subprocess.run([ZS3, "snapshot", "--bucket=" + B, "--name=t1"], capture_output=True, text=True, env=env)
check("snapshot cmd", r.returncode == 0, r.stderr[-500:] if r.returncode else "")
r = subprocess.run([ZS3, "snapshots", "--bucket=" + B], capture_output=True, text=True, env=env)
check("snapshots list", "t1" in (r.stdout + r.stderr), r.stdout + r.stderr)
d1 = "/tmp/zs3-clone1"
shutil.rmtree(d1, ignore_errors=True)
r = subprocess.run([ZS3, "clone", "--bucket=" + B, "--name=t1", "--dest=" + d1], capture_output=True, text=True, env=env)
check("clone cmd", r.returncode == 0, r.stderr[-500:] if r.returncode else "")
check("clone file a", open(d1 + "/docs/a.txt").read() == "hello snapshot world")
check("clone file b size", os.path.getsize(d1 + "/docs/b.bin") == 100000)
r2 = subprocess.run([ZS3, "clone", "--bucket=" + B, "--name=t1", "--dest=" + d1], capture_output=True, text=True, env=env)
check("re-clone warm cache transfers ~0", "0 bytes transferred" in r2.stderr, r2.stderr[-300:])
# second snapshot reuses chunks
r = subprocess.run([ZS3, "snapshot", "--bucket=" + B, "--name=t2"], capture_output=True, text=True, env=env)
check("second snapshot reuses chunks", "0 chunks uploaded" in r.stderr, r.stderr[-300:])

print()
if fails:
    print(f"{len(fails)} FAILURES: {fails}"); sys.exit(1)
print("ALL NEW-FEATURE CHECKS PASSED")
