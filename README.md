# zs3

Turn any directory into an S3 server. One static binary, no runtime, no
control plane, no dependency tree.

```bash
zs3 --data-dir=/srv/media
aws --endpoint-url http://localhost:9000 s3 ls s3://photos/
```

Each top-level directory under `--data-dir` is a bucket, and your files stay
files: `photos/2024/img.jpg` is `/srv/media/photos/2024/img.jpg`, so you can
`ls` a bucket and `cp` into one. zs3 runs standalone;
`zs3 snapshot` and `zs3 clone` move content-addressed bucket snapshots between
machines, transferring only the blocks the destination lacks.

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

Or build it. Requires Zig 0.16.0, which is where the `std.Io` APIs zs3 uses
were added; 0.15.x does not compile it.

```bash
zig build -Doptimize=ReleaseSmall     # native
zig build -Dtarget=x86_64-linux-musl \
  -Dcpu=baseline -Doptimize=ReleaseSmall   # static Linux, ~440KB
```

## Size

Most local object-storage usage is PUT, GET, DELETE, LIST, and SigV4. zs3 does
that job instead of chasing parity with a production storage platform.

| | zs3 | RustFS | MinIO |
|---|-----|--------|-------|
| Lines (`wc -l main.zig acl.zig build.zig`) | ~7,050 | ~80,000 | 200,000 |
| Binary (static musl, `ReleaseSmall`) | ~500KB x86-64 / ~450KB aarch64 | ~50MB | 100MB |
| RAM idle | 3MB | ~100MB | 200MB+ |
| Dependencies | 0 | ~200 crates | many |

It is also fast: 7-124x lower latency than RustFS and Garage on the same
machine. Tables in [docs/benchmarks.md](docs/benchmarks.md).

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

## What works

SigV4 in both header and presigned query-string form. PUT, GET, HEAD, DELETE,
LIST v2, HeadBucket, DeleteObjects, multipart upload, CopyObject and
UploadPartCopy (so `aws s3 mv/sync` and `rclone move` work), ListParts. Range
requests per RFC 7233. Content-Type and `x-amz-meta-*` stored per object.
`x-amz-checksum-*` accepted and stored, including chunked trailers. HTTP
100-continue. Conditional writes via `If-Match` and `If-None-Match`, which is
enough for compare-and-swap protocols like SlateDB's ([how that
works](docs/conditional-writes.md)).

Writes fsync before they are acknowledged, so an acknowledged PUT survives a
power cut. `--fast` turns that off for benchmarks.

Request-by-request detail: [docs/api.md](docs/api.md).

### Snapshots

```bash
zs3 snapshot --bucket=artifacts --name=v1   # chunk + manifest, uploads missing blocks only
zs3 clone --bucket=artifacts --name=v1 --dest=./v1
zs3 snapshots --bucket=artifacts
```

A warm re-clone transfers close to nothing. Format and behavior in
[docs/snapshots.md](docs/snapshots.md).

## What doesn't

Versioning, lifecycle policies, bucket ACLs, object tagging, encryption, TLS
(terminate it in a proxy). If you need those, use MinIO or AWS. zs3 trades
feature parity for size and auditability.

There is also a peer-to-peer distributed mode in the binary. It works, and it
is frozen: snapshots are the supported way to move data between machines.
Details in [docs/distributed.md](docs/distributed.md), reasoning in
[docs/vision.md](docs/vision.md).

## Where it fits

Local dev in place of a MinIO service in Compose, CI artifact storage, agent
artifacts, self-hosted backups, edge and embedded appliances, and reading the
source to see how S3 works. The SigV4 implementation is about 150 lines:
canonical request, string to sign, HMAC chain, compare.

## Contributing

Tests and how to run them: [docs/testing.md](docs/testing.md). Security
posture and size limits: [docs/security.md](docs/security.md). Changes worth
knowing about: [CHANGELOG.md](CHANGELOG.md).

## License

[WTFPL](LICENSE). Read it, fork it, break it.
