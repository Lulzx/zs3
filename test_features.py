#!/usr/bin/env python3
"""Versioning, lifecycle, ACLs, tagging, and server-side encryption.
Requires a standalone server on :9000 started with --lifecycle-interval-s=2
(lifecycle checks wait for two passes). Set ZS3_DATA_DIR to the server's data
directory to also verify that encrypted objects are ciphertext on disk."""
import base64, hashlib, os, sys, time, urllib.request, urllib.error
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

ENDPOINT = os.environ.get("ZS3_ENDPOINT", "http://127.0.0.1:9000")
s3 = boto3.client("s3", endpoint_url=ENDPOINT,
    aws_access_key_id="minioadmin", aws_secret_access_key="minioadmin",
    config=Config(s3={"addressing_style": "path"}))
fails = []
def check(name, cond, extra=""):
    print(("  [PASS] " if cond else "  [FAIL] ") + name + (f" ({extra})" if extra and not cond else ""))
    if not cond: fails.append(name)
def err_code(fn):
    try: fn(); return None
    except ClientError as e: return e.response["Error"]["Code"]
def anon(method, path, body=None, headers=None):
    req = urllib.request.Request(ENDPOINT + path, method=method, data=body, headers=headers or {})
    try: return urllib.request.urlopen(req).status
    except urllib.error.HTTPError as e: return e.code
def hdr(resp, name):
    return resp["ResponseMetadata"]["HTTPHeaders"].get(name.lower())
def wipe(bucket):
    try:
        pages = s3.get_paginator("list_object_versions").paginate(Bucket=bucket)
        for page in pages:
            objs = [{"Key": v["Key"], "VersionId": v["VersionId"]} for v in page.get("Versions", []) + page.get("DeleteMarkers", [])]
            if objs: s3.delete_objects(Bucket=bucket, Delete={"Objects": objs, "Quiet": True})
        for o in s3.list_objects_v2(Bucket=bucket).get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=o["Key"])
        s3.delete_bucket(Bucket=bucket)
    except ClientError: pass

# ---------------------------------------------------------------- versioning
print("== versioning")
B = "feat-versioning"; wipe(B); s3.create_bucket(Bucket=B)
check("versioning off by default", "Status" not in s3.get_bucket_versioning(Bucket=B))
s3.put_object(Bucket=B, Key="k", Body=b"v0")            # pre-versioning => null version
s3.put_bucket_versioning(Bucket=B, VersioningConfiguration={"Status": "Enabled"})
check("versioning enabled", s3.get_bucket_versioning(Bucket=B)["Status"] == "Enabled")
check("IllegalVersioningConfiguration on bad status",
      err_code(lambda: s3.put_bucket_versioning(Bucket=B, VersioningConfiguration={"Status": "Nope"})) == "IllegalVersioningConfigurationException")
r1 = s3.put_object(Bucket=B, Key="k", Body=b"v1")
r2 = s3.put_object(Bucket=B, Key="k", Body=b"v2", Metadata={"gen": "2"})
v1, v2 = r1["VersionId"], r2["VersionId"]
check("PUT returns version ids", v1 and v2 and v1 != v2 and v1 != "null", f"{v1} {v2}")
check("GET latest", s3.get_object(Bucket=B, Key="k")["Body"].read() == b"v2")
check("GET latest carries VersionId", s3.get_object(Bucket=B, Key="k")["VersionId"] == v2)
check("GET ?versionId=v1", s3.get_object(Bucket=B, Key="k", VersionId=v1)["Body"].read() == b"v1")
check("GET ?versionId=null (pre-versioning)", s3.get_object(Bucket=B, Key="k", VersionId="null")["Body"].read() == b"v0")
check("HEAD ?versionId", s3.head_object(Bucket=B, Key="k", VersionId=v2)["Metadata"] == {"gen": "2"})
check("HEAD ?versionId=v1 has no metadata", s3.head_object(Bucket=B, Key="k", VersionId=v1).get("Metadata", {}) == {})
check("NoSuchVersion", err_code(lambda: s3.get_object(Bucket=B, Key="k", VersionId="0" * 32)) == "NoSuchVersion")
lv = s3.list_object_versions(Bucket=B)
vers = lv.get("Versions", [])
check("ListObjectVersions has 3 versions", len(vers) == 3, str([(v["VersionId"], v["IsLatest"]) for v in vers]))
check("ListObjectVersions order newest first", [v["VersionId"] for v in vers] == [v2, v1, "null"], str([v["VersionId"] for v in vers]))
check("IsLatest only on newest", [v["IsLatest"] for v in vers] == [True, False, False])
check("ListObjectVersions ETag", vers[0]["ETag"] == '"' + hashlib.md5(b"v2").hexdigest() + '"')
check("ListObjectVersions Size", [v["Size"] for v in vers] == [2, 2, 2])
check("LIST v2 shows one key", [o["Key"] for o in s3.list_objects_v2(Bucket=B)["Contents"]] == ["k"])
# delete -> marker
d = s3.delete_object(Bucket=B, Key="k")
check("DELETE creates delete marker", d.get("DeleteMarker") is True and d.get("VersionId"), str(d))
marker = d["VersionId"]
check("GET after marker is 404", err_code(lambda: s3.get_object(Bucket=B, Key="k")) == "NoSuchKey")
try: s3.head_object(Bucket=B, Key="k"); check("HEAD after marker 404", False)
except ClientError as e: check("HEAD after marker 404 + x-amz-delete-marker", e.response["ResponseMetadata"]["HTTPHeaders"].get("x-amz-delete-marker") == "true")
check("LIST v2 hides deleted key", "Contents" not in s3.list_objects_v2(Bucket=B))
lv = s3.list_object_versions(Bucket=B)
check("delete marker listed and latest", lv["DeleteMarkers"][0]["VersionId"] == marker and lv["DeleteMarkers"][0]["IsLatest"] is True)
check("old versions still readable", s3.get_object(Bucket=B, Key="k", VersionId=v1)["Body"].read() == b"v1")
check("GET a delete marker version -> 405", err_code(lambda: s3.get_object(Bucket=B, Key="k", VersionId=marker)) == "MethodNotAllowed")
# remove marker -> restores v2
s3.delete_object(Bucket=B, Key="k", VersionId=marker)
check("deleting the marker restores latest", s3.get_object(Bucket=B, Key="k")["Body"].read() == b"v2")
check("restored object keeps its version id", s3.head_object(Bucket=B, Key="k")["VersionId"] == v2)
# delete specific current version -> promotes v1
s3.delete_object(Bucket=B, Key="k", VersionId=v2)
check("deleting current version promotes previous", s3.get_object(Bucket=B, Key="k")["Body"].read() == b"v1")
check("promoted version id", s3.head_object(Bucket=B, Key="k")["VersionId"] == v1)
check("delete nonexistent version -> NoSuchVersion", err_code(lambda: s3.delete_object(Bucket=B, Key="k", VersionId="f" * 32)) == "NoSuchVersion")
# copy from a version
s3.copy_object(Bucket=B, Key="k-copy", CopySource={"Bucket": B, "Key": "k", "VersionId": "null"})
check("CopyObject from versionId", s3.get_object(Bucket=B, Key="k-copy")["Body"].read() == b"v0")
check("copy gets its own version id", s3.head_object(Bucket=B, Key="k-copy")["VersionId"] not in ("null", v1))
# multi delete with version ids and markers
r = s3.delete_objects(Bucket=B, Delete={"Objects": [{"Key": "k-copy"}, {"Key": "k", "VersionId": "null"}]})
dm = {x["Key"]: x for x in r["Deleted"]}
check("DeleteObjects marker for versionless entry", dm["k-copy"].get("DeleteMarker") is True and dm["k-copy"].get("DeleteMarkerVersionId"))
check("DeleteObjects permanent for versioned entry", dm["k"].get("VersionId") == "null" and not dm["k"].get("DeleteMarker"))
check("multipart under versioning", True)
mp = s3.create_multipart_upload(Bucket=B, Key="big")
parts = []
for i in range(1, 3):
    parts.append({"PartNumber": i, "ETag": s3.upload_part(Bucket=B, Key="big", UploadId=mp["UploadId"], PartNumber=i, Body=b"x" * (5 * 1024 * 1024))["ETag"]})
c = s3.complete_multipart_upload(Bucket=B, Key="big", UploadId=mp["UploadId"], MultipartUpload={"Parts": parts})
check("CompleteMultipart returns VersionId", c.get("VersionId") not in (None, "null"), str(c.get("VersionId")))
# suspended
s3.put_bucket_versioning(Bucket=B, VersioningConfiguration={"Status": "Suspended"})
r = s3.put_object(Bucket=B, Key="s", Body=b"a")
check("suspended PUT -> null version", r.get("VersionId") == "null", str(r.get("VersionId")))
s3.put_object(Bucket=B, Key="s", Body=b"b")
sv = [v for v in s3.list_object_versions(Bucket=B, Prefix="s").get("Versions", [])]
check("suspended overwrites null in place", len(sv) == 1 and sv[0]["VersionId"] == "null", str(sv))
d = s3.delete_object(Bucket=B, Key="s")
check("suspended DELETE -> null delete marker", d.get("DeleteMarker") is True and d.get("VersionId") == "null", str(d))
check("bucket with versions is not empty", err_code(lambda: s3.delete_bucket(Bucket=B)) == "BucketNotEmpty")
# pagination
s3.put_bucket_versioning(Bucket=B, VersioningConfiguration={"Status": "Enabled"})
for i in range(3): s3.put_object(Bucket=B, Key="pg", Body=str(i).encode())
seen = []
kw = {}
while True:
    page = s3.list_object_versions(Bucket=B, Prefix="pg", MaxKeys=2, **kw)
    seen += [v["VersionId"] for v in page.get("Versions", [])]
    if not page.get("IsTruncated"): break
    kw = {"KeyMarker": page["NextKeyMarker"], "VersionIdMarker": page["NextVersionIdMarker"]}
check("ListObjectVersions pagination", len(seen) == 3 and len(set(seen)) == 3, str(seen))
# delimiter
s3.put_object(Bucket=B, Key="dir/a", Body=b"1"); s3.put_object(Bucket=B, Key="dir/b", Body=b"2")
lv = s3.list_object_versions(Bucket=B, Delimiter="/")
check("ListObjectVersions CommonPrefixes", any(p["Prefix"] == "dir/" for p in lv.get("CommonPrefixes", [])) and not any(v["Key"].startswith("dir/") for v in lv.get("Versions", [])))
wipe(B)
check("wipe + delete versioned bucket", err_code(lambda: s3.head_bucket(Bucket=B)) is not None)

# --------------------------------------------------------------- encryption
print("== encryption")
B = "feat-sse"; wipe(B); s3.create_bucket(Bucket=B)
body = os.urandom(200_000)
r = s3.put_object(Bucket=B, Key="s3.bin", Body=body, ServerSideEncryption="AES256", Metadata={"m": "1"})
check("PUT SSE-S3 echoes header", r.get("ServerSideEncryption") == "AES256")
check("PUT SSE-S3 ETag is plaintext md5", r["ETag"] == '"' + hashlib.md5(body).hexdigest() + '"')
g = s3.get_object(Bucket=B, Key="s3.bin")
check("GET SSE-S3 decrypts", g["Body"].read() == body)
check("GET SSE-S3 header", g.get("ServerSideEncryption") == "AES256" and g["Metadata"] == {"m": "1"})
h = s3.head_object(Bucket=B, Key="s3.bin")
check("HEAD SSE-S3 length is plaintext length", h["ContentLength"] == len(body) and h["ETag"] == r["ETag"])
check("range GET on encrypted", s3.get_object(Bucket=B, Key="s3.bin", Range="bytes=70000-140000")["Body"].read() == body[70000:140001])
check("LIST size is plaintext size", [o["Size"] for o in s3.list_objects_v2(Bucket=B)["Contents"] if o["Key"] == "s3.bin"] == [len(body)])
data_dir = os.environ.get("ZS3_DATA_DIR")
if data_dir:
    raw = open(os.path.join(data_dir, B, "s3.bin"), "rb").read()
    check("file on disk is ciphertext", raw[:4] == b"ZS3E" and body[:64] not in raw, str(raw[:8]))
else:
    print("  [SKIP] file on disk is ciphertext (set ZS3_DATA_DIR to enable)")
check("conditional GET on encrypted (304)", err_code(lambda: s3.get_object(Bucket=B, Key="s3.bin", IfNoneMatch=r["ETag"])) == "304")
# SSE-C
key = os.urandom(32); key_b64 = base64.b64encode(key).decode(); key_md5 = base64.b64encode(hashlib.md5(key).digest()).decode()
ssec = dict(SSECustomerAlgorithm="AES256", SSECustomerKey=key_b64, SSECustomerKeyMD5=key_md5)
r = s3.put_object(Bucket=B, Key="c.bin", Body=body, **ssec)
check("PUT SSE-C echoes key md5", r.get("SSECustomerKeyMD5") == key_md5 and r.get("SSECustomerAlgorithm") == "AES256")
check("GET SSE-C with key", s3.get_object(Bucket=B, Key="c.bin", **ssec)["Body"].read() == body)
check("GET SSE-C without key -> 400", err_code(lambda: s3.get_object(Bucket=B, Key="c.bin")) == "InvalidRequest")
wrong = os.urandom(32)
bad = dict(SSECustomerAlgorithm="AES256", SSECustomerKey=base64.b64encode(wrong).decode(), SSECustomerKeyMD5=base64.b64encode(hashlib.md5(wrong).digest()).decode())
check("GET SSE-C wrong key -> 403", err_code(lambda: s3.get_object(Bucket=B, Key="c.bin", **bad)) == "AccessDenied")
check("HEAD SSE-C with key", s3.head_object(Bucket=B, Key="c.bin", **ssec)["ContentLength"] == len(body))
check("bad key md5 -> InvalidDigest", err_code(lambda: s3.put_object(Bucket=B, Key="x", Body=b"1", SSECustomerAlgorithm="AES256", SSECustomerKey=key_b64, SSECustomerKeyMD5="AAAA")) == "InvalidDigest")
check("aws:kms -> NotImplemented", err_code(lambda: s3.put_object(Bucket=B, Key="x", Body=b"1", ServerSideEncryption="aws:kms")) == "NotImplemented")
# copy: SSE-C source -> SSE-S3 dest, and plain
s3.copy_object(Bucket=B, Key="c-to-s3.bin", CopySource={"Bucket": B, "Key": "c.bin"},
    CopySourceSSECustomerAlgorithm="AES256", CopySourceSSECustomerKey=key_b64, CopySourceSSECustomerKeyMD5=key_md5, ServerSideEncryption="AES256")
check("copy SSE-C -> SSE-S3", s3.get_object(Bucket=B, Key="c-to-s3.bin")["Body"].read() == body)
s3.copy_object(Bucket=B, Key="plain-copy.bin", CopySource={"Bucket": B, "Key": "s3.bin"})
check("copy SSE-S3 -> plain", s3.get_object(Bucket=B, Key="plain-copy.bin")["Body"].read() == body and s3.head_object(Bucket=B, Key="plain-copy.bin").get("ServerSideEncryption") is None)
check("copy SSE-C without source key -> 400", err_code(lambda: s3.copy_object(Bucket=B, Key="nope", CopySource={"Bucket": B, "Key": "c.bin"})) == "InvalidRequest")
# bucket default encryption
check("no default encryption -> 404", err_code(lambda: s3.get_bucket_encryption(Bucket=B)) == "ServerSideEncryptionConfigurationNotFoundError")
s3.put_bucket_encryption(Bucket=B, ServerSideEncryptionConfiguration={"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]})
check("get default encryption", s3.get_bucket_encryption(Bucket=B)["ServerSideEncryptionConfiguration"]["Rules"][0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "AES256")
r = s3.put_object(Bucket=B, Key="auto.bin", Body=b"auto")
check("default encryption applies to PUT", r.get("ServerSideEncryption") == "AES256" and s3.get_object(Bucket=B, Key="auto.bin")["Body"].read() == b"auto")
check("kms default -> NotImplemented", err_code(lambda: s3.put_bucket_encryption(Bucket=B, ServerSideEncryptionConfiguration={"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]})) == "NotImplemented")
s3.delete_bucket_encryption(Bucket=B)
check("delete default encryption", err_code(lambda: s3.get_bucket_encryption(Bucket=B)) == "ServerSideEncryptionConfigurationNotFoundError")
# multipart SSE-S3
big = os.urandom(6 * 1024 * 1024) + b"tail"
mp = s3.create_multipart_upload(Bucket=B, Key="mp-s3.bin", ServerSideEncryption="AES256", ContentType="application/x-test")
check("initiate SSE-S3 echoes", mp.get("ServerSideEncryption") == "AES256")
p1 = s3.upload_part(Bucket=B, Key="mp-s3.bin", UploadId=mp["UploadId"], PartNumber=1, Body=big[:5 * 1024 * 1024])
p2 = s3.upload_part(Bucket=B, Key="mp-s3.bin", UploadId=mp["UploadId"], PartNumber=2, Body=big[5 * 1024 * 1024:])
check("upload_part SSE-S3 ETag is plaintext md5", p1["ETag"] == '"' + hashlib.md5(big[:5 * 1024 * 1024]).hexdigest() + '"')
lp = s3.list_parts(Bucket=B, Key="mp-s3.bin", UploadId=mp["UploadId"])
check("list_parts plaintext sizes", [p["Size"] for p in lp["Parts"]] == [5 * 1024 * 1024, len(big) - 5 * 1024 * 1024], str([p["Size"] for p in lp["Parts"]]))
c = s3.complete_multipart_upload(Bucket=B, Key="mp-s3.bin", UploadId=mp["UploadId"], MultipartUpload={"Parts": [{"PartNumber": 1, "ETag": p1["ETag"]}, {"PartNumber": 2, "ETag": p2["ETag"]}]})
check("complete SSE-S3 echoes", c.get("ServerSideEncryption") == "AES256")
g = s3.get_object(Bucket=B, Key="mp-s3.bin")
check("multipart SSE-S3 roundtrip", g["Body"].read() == big)
check("multipart uses initiate content-type", g["ContentType"] == "application/x-test")
check("multipart composite etag on HEAD", s3.head_object(Bucket=B, Key="mp-s3.bin")["ETag"].endswith('-2"'))
check("multipart range on encrypted", s3.get_object(Bucket=B, Key="mp-s3.bin", Range="bytes=-4")["Body"].read() == b"tail")
# multipart SSE-C (key on each part and on complete)
mp = s3.create_multipart_upload(Bucket=B, Key="mp-c.bin", **ssec)
p1 = s3.upload_part(Bucket=B, Key="mp-c.bin", UploadId=mp["UploadId"], PartNumber=1, Body=big[:5 * 1024 * 1024], **ssec)
check("upload_part SSE-C without key -> 400", err_code(lambda: s3.upload_part(Bucket=B, Key="mp-c.bin", UploadId=mp["UploadId"], PartNumber=2, Body=b"x")) == "InvalidRequest")
p2 = s3.upload_part(Bucket=B, Key="mp-c.bin", UploadId=mp["UploadId"], PartNumber=2, Body=big[5 * 1024 * 1024:], **ssec)
c = s3.complete_multipart_upload(Bucket=B, Key="mp-c.bin", UploadId=mp["UploadId"], MultipartUpload={"Parts": [{"PartNumber": 1, "ETag": p1["ETag"]}, {"PartNumber": 2, "ETag": p2["ETag"]}]}, **ssec)
check("multipart SSE-C roundtrip", s3.get_object(Bucket=B, Key="mp-c.bin", **ssec)["Body"].read() == big)
# upload_part_copy from encrypted source into SSE-S3 upload
mp = s3.create_multipart_upload(Bucket=B, Key="mp-copy.bin", ServerSideEncryption="AES256")
pc = s3.upload_part_copy(Bucket=B, Key="mp-copy.bin", UploadId=mp["UploadId"], PartNumber=1, CopySource={"Bucket": B, "Key": "mp-s3.bin"}, CopySourceRange="bytes=0-5242879")
pc2 = s3.upload_part_copy(Bucket=B, Key="mp-copy.bin", UploadId=mp["UploadId"], PartNumber=2, CopySource={"Bucket": B, "Key": "mp-s3.bin"}, CopySourceRange=f"bytes=5242880-{len(big)-1}")
s3.complete_multipart_upload(Bucket=B, Key="mp-copy.bin", UploadId=mp["UploadId"], MultipartUpload={"Parts": [{"PartNumber": 1, "ETag": pc["CopyPartResult"]["ETag"]}, {"PartNumber": 2, "ETag": pc2["CopyPartResult"]["ETag"]}]})
check("upload_part_copy from encrypted source", s3.get_object(Bucket=B, Key="mp-copy.bin")["Body"].read() == big)
# empty object
s3.put_object(Bucket=B, Key="empty", Body=b"", ServerSideEncryption="AES256")
check("empty encrypted object", s3.get_object(Bucket=B, Key="empty")["Body"].read() == b"" and s3.head_object(Bucket=B, Key="empty")["ContentLength"] == 0)
# versioning + encryption together
s3.put_bucket_versioning(Bucket=B, VersioningConfiguration={"Status": "Enabled"})
r = s3.put_object(Bucket=B, Key="ve", Body=b"one", ServerSideEncryption="AES256")
s3.put_object(Bucket=B, Key="ve", Body=b"two", ServerSideEncryption="AES256")
check("old encrypted version readable", s3.get_object(Bucket=B, Key="ve", VersionId=r["VersionId"])["Body"].read() == b"one")
lv = [(v["VersionId"], v["Size"], v["ETag"]) for v in s3.list_object_versions(Bucket=B, Prefix="ve")["Versions"]]
check("ListObjectVersions plaintext size/etag for encrypted", all(sz == 3 for _, sz, _ in lv) and lv[1][2] == '"' + hashlib.md5(b"one").hexdigest() + '"', str(lv))
wipe(B)

# ---------------------------------------------------------------- lifecycle
print("== lifecycle")
B = "feat-lifecycle"; wipe(B); s3.create_bucket(Bucket=B)
check("no lifecycle -> 404", err_code(lambda: s3.get_bucket_lifecycle_configuration(Bucket=B)) == "NoSuchLifecycleConfiguration")
check("transition rejected", err_code(lambda: s3.put_bucket_lifecycle_configuration(Bucket=B, LifecycleConfiguration={"Rules": [{"ID": "t", "Status": "Enabled", "Filter": {}, "Transitions": [{"Days": 1, "StorageClass": "GLACIER"}]}]})) == "NotImplemented")
check("rule without action rejected", err_code(lambda: s3.put_bucket_lifecycle_configuration(Bucket=B, LifecycleConfiguration={"Rules": [{"ID": "x", "Status": "Enabled", "Filter": {}}]})) in ("InvalidArgument", "MalformedXML"))
s3.put_object(Bucket=B, Key="old/a.txt", Body=b"a"); s3.put_object(Bucket=B, Key="old/b.txt", Body=b"b", Tagging="keep=yes")
s3.put_object(Bucket=B, Key="new/c.txt", Body=b"c")
s3.put_object(Bucket=B, Key="tagged/d.txt", Body=b"d", Tagging="tier=tmp")
s3.put_object(Bucket=B, Key="tagged/e.txt", Body=b"e", Tagging="tier=perm")
mp = s3.create_multipart_upload(Bucket=B, Key="old/stale-upload")
rules = {"Rules": [
    {"ID": "expire-old", "Status": "Enabled", "Filter": {"Prefix": "old/"}, "Expiration": {"Date": "2020-01-01T00:00:00Z"},
     "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 0}},
    {"ID": "expire-tag", "Status": "Enabled", "Filter": {"Tag": {"Key": "tier", "Value": "tmp"}}, "Expiration": {"Days": 0}},
    {"ID": "disabled", "Status": "Disabled", "Filter": {"Prefix": "new/"}, "Expiration": {"Days": 0}},
]}
s3.put_bucket_lifecycle_configuration(Bucket=B, LifecycleConfiguration=rules)
got = s3.get_bucket_lifecycle_configuration(Bucket=B)["Rules"]
check("lifecycle roundtrip", [r["ID"] for r in got] == ["expire-old", "expire-tag", "disabled"], str(got))
time.sleep(5)
keys = sorted(o["Key"] for o in s3.list_objects_v2(Bucket=B).get("Contents", []))
check("prefix rule expired old/*", not any(k.startswith("old/") for k in keys), str(keys))
check("disabled rule did nothing", "new/c.txt" in keys, str(keys))
check("tag rule expired only matching tag", "tagged/e.txt" in keys and "tagged/d.txt" not in keys, str(keys))
check("stale multipart aborted", err_code(lambda: s3.list_parts(Bucket=B, Key="old/stale-upload", UploadId=mp["UploadId"])) == "NoSuchUpload")
# noncurrent + delete marker cleanup
s3.put_bucket_versioning(Bucket=B, VersioningConfiguration={"Status": "Enabled"})
s3.put_object(Bucket=B, Key="v/x", Body=b"1"); s3.put_object(Bucket=B, Key="v/x", Body=b"2")
s3.put_object(Bucket=B, Key="v/gone", Body=b"g"); s3.delete_object(Bucket=B, Key="v/gone")
lv = s3.list_object_versions(Bucket=B, Prefix="v/gone")
s3.delete_object(Bucket=B, Key="v/gone", VersionId=lv["Versions"][0]["VersionId"])   # leave only the marker
s3.put_bucket_lifecycle_configuration(Bucket=B, LifecycleConfiguration={"Rules": [
    {"ID": "nc", "Status": "Enabled", "Filter": {"Prefix": "v/"}, "NoncurrentVersionExpiration": {"NoncurrentDays": 0},
     "Expiration": {"ExpiredObjectDeleteMarker": True}}]})
time.sleep(5)
lv = s3.list_object_versions(Bucket=B, Prefix="v/")
check("noncurrent versions expired", [(v["Key"], v["IsLatest"]) for v in lv.get("Versions", [])] == [("v/x", True)], str(lv.get("Versions")))
check("current object intact", s3.get_object(Bucket=B, Key="v/x")["Body"].read() == b"2")
check("orphan delete marker removed", "DeleteMarkers" not in lv, str(lv.get("DeleteMarkers")))
s3.delete_bucket_lifecycle(Bucket=B)
check("delete lifecycle", err_code(lambda: s3.get_bucket_lifecycle_configuration(Bucket=B)) == "NoSuchLifecycleConfiguration")
wipe(B)

# ------------------------------------------------------------- acl + tagging
print("== acl + tagging")
B = "feat-acl"; wipe(B); s3.create_bucket(Bucket=B, ACL="public-read")
s3.put_object(Bucket=B, Key="o", Body=b"o", Tagging="a=1")
check("anon GET on public-read bucket", anon("GET", f"/{B}/o") == 200)
check("anon PUT on public-read bucket -> 403", anon("PUT", f"/{B}/x", b"1") == 403)
check("anon PUT ?tagging -> 403", anon("PUT", f"/{B}/o?tagging", b"<Tagging/>") == 403)
s3.put_bucket_acl(Bucket=B, ACL="private")
check("anon GET after private -> 403", anon("GET", f"/{B}/o") == 403)
s3.put_object_acl(Bucket=B, Key="o", ACL="public-read")
check("object public-read", anon("GET", f"/{B}/o") == 200)
check("object tags via PUT header", s3.get_object_tagging(Bucket=B, Key="o")["TagSet"] == [{"Key": "a", "Value": "1"}])
check("x-amz-tagging-count", hdr(s3.head_object(Bucket=B, Key="o"), "x-amz-tagging-count") == "1")
wipe(B)

print()
print(f"{'ALL FEATURE CHECKS PASSED' if not fails else 'FAILED: ' + ', '.join(fails)}")
sys.exit(1 if fails else 0)
