# zs3

Turn any directory into an S3 server. zs3 is a single static binary under
1MB that speaks the S3 API over files you already have.

```bash
zs3 --data-dir=/srv/media
aws --endpoint-url http://localhost:9000 s3 ls s3://photos/
```

Each top-level directory under `--data-dir` is a bucket, and your files stay
files: `photos/2024/img.jpg` is `/srv/media/photos/2024/img.jpg`, so you can
`ls` a bucket and `cp` into one. To move data to another machine,
`zs3 snapshot` and `zs3 clone` copy content-addressed bucket snapshots,
transferring only the blocks the destination lacks.

Start with the [documentation index](docs/README.md), or jump to
[configuration](docs/configuration.md), the [API subset](docs/api.md),
[snapshots](docs/snapshots.md), or
[replacing MinIO](docs/replace-minio.md).

## Install

```bash
# Docker (GHCR, multi-arch)
docker run -p 9000:9000 -v zs3-data:/data \
  ghcr.io/lulzx/zs3 --acl=admin:local-access:local-secret

# Static binary
curl -fsSL https://github.com/Lulzx/zs3/releases/latest/download/zs3-x86_64-linux-musl -o zs3
chmod +x zs3 && ./zs3

# Homebrew (tap setup in packaging/homebrew/zs3.rb)
brew tap Lulzx/zs3 && brew install zs3
```

To build from source you need Zig 0.16.0. zs3 uses the `std.Io` APIs added in
that release, so 0.15.x does not compile it.

```bash
zig build -Doptimize=ReleaseSmall     # native
zig build -Dtarget=x86_64-linux-musl \
  -Dcpu=baseline -Doptimize=ReleaseSmall   # static Linux, ~940KB
zig build -Doptimize=ReleaseSmall -Dtls=false  # ~660KB: no https:// client for snapshot/clone
```

## How it compares

Most local object-storage usage is PUT, GET, DELETE, LIST, and SigV4. zs3 does
that job instead of chasing parity with a production storage platform.

| | zs3 | RustFS | MinIO |
|---|-----|--------|-------|
| Lines (`wc -l main.zig acl.zig build.zig`) | ~10,000 | ~80,000 | 200,000 |
| Binary (static musl, `ReleaseSmall`) | ~940KB x86-64 / ~840KB aarch64 (`-Dtls=false`: ~660KB / ~600KB) | ~50MB | 100MB |
| RAM idle | 3MB | ~100MB | 200MB+ |
| Dependencies | 0 | ~200 crates | many |

On the same machine it answers requests 7-124x faster than RustFS and Garage,
depending on the operation. Tables in [docs/benchmarks.md](docs/benchmarks.md).

## Quick start

```bash
./zig-out/bin/zs3
```

Listens on 9000, stores data in `./data`, accepts `minioadmin:minioadmin`.
Set real credentials with `--acl="admin:key:secret"` before exposing it to
anything. Full flag list in [docs/configuration.md](docs/configuration.md).

```bash
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin

aws --endpoint-url http://localhost:9000 s3 mb s3://mybucket
aws --endpoint-url http://localhost:9000 s3 cp file.txt s3://mybucket/
aws --endpoint-url http://localhost:9000 s3 ls s3://mybucket/ --recursive
```

boto3, aws-cli, and rclone all work unmodified. `./scripts/verify-clients.sh`
reproduces the compatibility check.

Open `http://localhost:9000/_zs3/console` for a browser console (buckets,
upload, download, delete). It signs requests in-browser with keys you enter,
kept in localStorage. `http://localhost:9000/metrics` serves Prometheus
counters.

## Supported S3 surface

SigV4 in both header and presigned query-string form. PUT, GET, HEAD, DELETE,
LIST v2, HeadBucket, DeleteObjects, multipart upload, CopyObject and
UploadPartCopy (so `aws s3 mv/sync` and `rclone move` work), ListParts. Range
requests per RFC 7233. Content-Type and `x-amz-meta-*` stored per object.
`x-amz-checksum-*` accepted and stored, including chunked trailers. HTTP
100-continue. Conditional writes via `If-Match` and `If-None-Match`, which is
enough for compare-and-swap protocols like SlateDB's ([how that
works](docs/conditional-writes.md)).

Bucket versioning with delete markers and ListObjectVersions. Lifecycle rules
(expiration by age or date, noncurrent-version and delete-marker cleanup,
incomplete-multipart abort) evaluated by a background thread. Object and
bucket tagging. Canned ACLs, so `public-read` buckets and objects serve
unsigned GETs. Server-side encryption at rest with a server key (SSE-S3) or a
caller-supplied key (SSE-C), including bucket default encryption. All of it is
files under the bucket: versions in `.zs3versions/`, settings in
`.zs3bucket/`, so `ls` still shows the current objects.

Writes fsync before they are acknowledged, so an acknowledged PUT survives a
power cut. `--fast` turns that off for benchmarks.

Request-by-request detail: [docs/api.md](docs/api.md).

### Snapshots

```bash
zs3 snapshot --bucket=artifacts --name=v1   # chunk + manifest, uploads missing blocks only
zs3 clone --bucket=artifacts --name=v1 --dest=./v1
zs3 snapshots --bucket=artifacts
zs3 clone --endpoint=https://s3.amazonaws.com --bucket=artifacts --name=v1 --dest=./v1
```

A re-clone against a warm cache transfers the manifest and nothing else. The
store can be any S3 server, over `http://` or `https://` (system CA store,
`--ca-file` for a private CA). Format and behavior in
[docs/snapshots.md](docs/snapshots.md).

## Not supported

Bucket policies and IAM (access is the three roles plus canned ACLs), object
lock, KMS-managed keys (`aws:kms` is refused; AES256 is the only SSE
algorithm), storage classes and lifecycle transitions, cross-bucket
replication rules, event notifications, static website hosting, and
serving TLS itself (the server speaks plain HTTP; terminate TLS in a proxy,
the snapshot client speaks https). Versioning and encryption are standalone
mode only. If you need the rest, use MinIO or AWS. zs3 trades feature parity
for size and auditability.

The binary also carries a working peer-to-peer distributed mode, which is
frozen at its current state. Snapshots are the supported way to move data
between machines. Details in [docs/distributed.md](docs/distributed.md),
reasoning in [docs/vision.md](docs/vision.md).

## Uses

Local dev in place of a MinIO service in Compose, CI artifact storage, agent
artifacts, self-hosted backups, edge and embedded appliances, and reading the
source to see how S3 works. The SigV4 implementation is about 150 lines:
canonical request, string to sign, HMAC chain, compare.

## Working on zs3

[docs/testing.md](docs/testing.md) covers the unit, integration, and
client-compatibility suites. [docs/security.md](docs/security.md) covers what
the server validates and where the size limits sit.
[CHANGELOG.md](CHANGELOG.md) records what changed per release.

## License

[WTFPL](LICENSE).
