# zs3

**SQLite for objects.** Local, dev, and edge S3 storage in a small static
binary with no runtime, control plane, or dependency tree.

Run one file, point an existing S3 client at it, and keep the data on disk.
zs3 is standalone by default. `zs3 snapshot` / `zs3 clone` move
content-addressed bucket snapshots between machines, transferring only the
blocks the destination lacks. An experimental distributed mode remains in the
binary but is frozen; snapshots and clone are the supported path for moving
data between machines.

[Replace MinIO in Docker Compose](docs/replace-minio.md) ·
[Product direction](docs/vision.md) · [API subset](docs/api.md) ·
[Snapshots & clone](docs/snapshots.md)

## Why

Most local object-storage usage is PUT, GET, DELETE, LIST, and SigV4. zs3 owns
that narrow job instead of pursuing feature parity with a production object
storage platform.

| | zs3 | RustFS | MinIO |
|---|-----|--------|-------|
| Lines (server: `wc -l main.zig acl.zig build.zig`) | ~7,050 | ~80,000 | 200,000 |
| Binary (static Linux musl, `ReleaseSmall`) | ~500KB x86-64 / ~450KB aarch64 | ~50MB | 100MB |
| RAM idle | 3MB | ~100MB | 200MB+ |
| Dependencies | 0 | ~200 crates | many |

## What it does

**Standalone Mode:**
- Full AWS SigV4 authentication, header and presigned-URL (query-string) forms
  (verified with aws-cli, boto3, and rclone)
- PUT, GET, DELETE, HEAD, LIST (v2)
- HeadBucket for bucket existence checks
- CopyObject + UploadPartCopy (`aws s3 mv/sync`, `rclone move` work)
- ListParts for multipart inspection
- Content-Type and `x-amz-meta-*` stored per object, served on GET/HEAD
- SDK checksums accepted and stored (`x-amz-checksum-*`, checksum trailers)
- DeleteObjects batch operation
- Multipart uploads for large files
- Range requests for streaming/seeking (RFC 7233 compliant suffix ranges;
  whole-object checksums omitted from 206 responses, like S3)
- HTTP 100-continue support (boto3 compatible)
- AWS chunked transfer encoding support, including `-TRAILER` variants
- fsync-on-write by default (`--fast` disables it for benchmarks)
- Embedded browser console (`/_zs3/console`) and Prometheus `/metrics`
- Static Linux musl binary, zero dependencies

**Snapshots & clone:**
- `zs3 snapshot --bucket=B --name=N` chunks a bucket into content-addressed
  BLAKE3 blocks, uploading only missing chunks, and stores a manifest
- `zs3 clone --bucket=B --name=N --dest=DIR` fetches the manifest and
  downloads only blocks the local cache lacks (warm re-clones transfer ~nothing)

**Distributed Mode (IPFS-like):**
- Content-addressed storage with BLAKE3 hashing
- Automatic deduplication across the network
- Full Kademlia DHT for peer/content discovery
- Peer-to-peer content transfer with quorum reads
- Inline storage for small objects (<4KB)
- Tombstone-based deletes (prevents resurrection)
- Block garbage collector with grace period
- Zero-config LAN discovery ready
- Same S3 API - works with existing tools

## What it doesn't do

- Versioning, lifecycle policies, bucket ACLs
- Object tagging, encryption
- Anything you'd actually need a cloud provider for

If you need these, use MinIO or AWS. zs3 wins on size, inspectability, and
auditability—not feature parity.

## Quick Start

```bash
zig build -Doptimize=ReleaseSmall
./zig-out/bin/zs3
```

Server listens on port 9000, stores data in `./data`. Default credentials are
`minioadmin:minioadmin` (admin role) — **do not use in production**.

### Credentials & roles

Provide credentials at build time (`-Dacl-list=`) or runtime (`--acl=`):

```bash
./zig-out/bin/zs3 --acl="admin:akey:asec,reader:rkey:rsec,writer:wkey:wsec"
```

Format: `role:access_key:secret_key`, comma-separated. Roles:

| Role   | Allowed methods                              |
|--------|----------------------------------------------|
| admin  | all                                          |
| writer | GET, HEAD, OPTIONS, PUT, POST, DELETE        |
| reader | GET, HEAD, OPTIONS                           |

Other useful flags: `--port=PORT`, `--data-dir=PATH`, `--fast`, `--help`.

`--fast` disables fsync-on-write for benchmarks; see [Durability](#durability).

### Console and metrics

Open `http://localhost:9000/_zs3/console` for an embedded browser console
(list/create buckets, browse, upload, download, delete). The page needs no
server auth; it signs S3 requests in-browser with keys you enter (kept in
localStorage only).

`http://localhost:9000/metrics` exposes Prometheus text metrics
(request/error counters, byte counters, uptime, bucket and peer gauges).

## Distributed Mode

```bash
# Node 1
./zs3 --distributed --port=9000

# Node 2 (connects to Node 1)
./zs3 --distributed --port=9001 --bootstrap=localhost:9000

# Node 3
./zs3 --distributed --port=9002 --bootstrap=localhost:9000,localhost:9001
```

All nodes share the same S3 API. PUT on any node, GET from any node.

> **Status: frozen.** Distributed mode works and ships in the binary, but
> active development has stopped here. Live replication, DHT discovery, and
> gossip carry the correctness obligations of a distributed object store,
> which is not the job zs3 is optimized for. Use `zs3 snapshot` / `zs3
> clone` to move data between machines instead. The notes below describe the
> mode as it exists today.

How the namespace stays in sync: every PUT/DELETE pushes the bucket/key
metadata entry (and inline data for small objects) to all known peers
before acknowledging, so cross-node reads are immediately consistent.
Larger blobs are replicated to `REPLICATION_TARGET` nodes and announced in
the DHT by a background worker, off the write path; a GET that arrives
before replication lands falls back to fetching the blob from peers. A
joining node pulls the full index from its bootstrap peers and discovers
their peers, and a periodic gossip round (`--gossip-interval-ms`, default
30s) refreshes liveness and repairs the mesh after restarts or partitions.
Conflicts resolve last-write-wins at second granularity; deletes propagate
as tombstones.

**Storage Layout (distributed):**
```
data/
├── .node_id              # Persistent 160-bit node identity
├── .cas/                 # Content-Addressed Store
│   └── ab/abc123...blob  # Files stored by BLAKE3 hash
├── .index/               # S3 path → content hash mapping
│   └── bucket/key.meta
└── bucket/               # (standalone mode only)
```

**Peer Protocol:**
```bash
curl http://localhost:9000/_zs3/ping           # Node health + ID
curl http://localhost:9000/_zs3/peers          # Known peers
curl http://localhost:9000/_zs3/providers/HASH # Who has content
```

## Usage

```bash
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin

aws --endpoint-url http://localhost:9000 s3 mb s3://mybucket
aws --endpoint-url http://localhost:9000 s3 cp file.txt s3://mybucket/
aws --endpoint-url http://localhost:9000 s3 ls s3://mybucket/ --recursive
aws --endpoint-url http://localhost:9000 s3 cp s3://mybucket/file.txt ./
aws --endpoint-url http://localhost:9000 s3 rm s3://mybucket/file.txt
```

The supported API subset is verified with three real clients. Run
`./scripts/verify-clients.sh` to reproduce the compatibility check. A boto3
example:

```python
import boto3

s3 = boto3.client('s3',
    endpoint_url='http://localhost:9000',
    aws_access_key_id='minioadmin',
    aws_secret_access_key='minioadmin'
)

s3.create_bucket(Bucket='test')
s3.put_object(Bucket='test', Key='hello.txt', Body=b'world')
print(s3.get_object(Bucket='test', Key='hello.txt')['Body'].read())
```

## The interesting bits

**SigV4 is elegant.** The whole auth flow is ~150 lines. AWS's "complex" signature scheme is really just: canonical request -> string to sign -> HMAC chain -> compare. No magic.

**Storage is just files.** `mybucket/folder/file.txt` is literally `./data/mybucket/folder/file.txt`. You can `ls` your buckets. You can `cp` files in. It just works.

**Zig makes this easy.** No runtime, no GC, no hidden allocations, no surprise dependencies. The binary is just the code + syscalls.

## When to use this

- Local dev (replacing a MinIO service in Docker Compose)
- CI artifact storage
- Agent artifacts and reproducible evidence
- Self-hosted backups
- Edge and embedded appliances
- Learning how S3 actually works

## Snapshots: `git clone` for buckets

```bash
zs3 snapshot --bucket=artifacts --name=v1   # chunk + manifest, uploads only missing blocks
zs3 clone --bucket=artifacts --name=v1 --dest=./v1
zs3 snapshots --bucket=artifacts             # list snapshot names
```

Flags take `--endpoint=URL` (or `ZS3_ENDPOINT`) and standard `AWS_*` env vars.
Full format and behavior: [docs/snapshots.md](docs/snapshots.md).

## Durability

"SQLite for objects" is a crash-safety claim, so zs3 fsyncs file contents (and
best-effort parent directories) before acknowledging PUT, CopyObject,
multipart-complete, and snapshot writes. Atomic rename means a concurrent GET
never sees a half-written object; fsync means an acknowledged write survives a
crash or power loss.

The benchmark numbers below were measured with `--fast` (no fsync). If you
only need "it's on your disk", run `zs3 --fast`.

Both durability modes, measured side by side on the same machine (Apple
Silicon, macOS, sequential, 100 iterations):

| Operation | `--fast` (no fsync) | default (fsync) |
|-----------|--------------------:|----------------:|
| PUT 1KB   | 0.59ms | 0.59ms |
| PUT 64KB  | 0.68ms | 0.74ms |
| PUT 1MB   | 2.99ms | 3.05ms |
| GET 1KB   | 0.39ms | 0.37ms |
| GET 1MB   | 2.00ms | 2.05ms |
| DELETE    | 0.36ms | 0.37ms |

On this hardware the durable default is within noise of `--fast` for small
PUTs and reads; the honest headline is that the comparison numbers below were
taken in the faster mode, and the durable mode costs single-digit percent
there. fsync-slow disks (spinning rust, some NFS) will show a bigger gap.
Reproduce with `python3 benchmark.py --only zs3` against a server with and
without `--fast`.

## When NOT to use this

- Production with untrusted users
- If you need any feature in the "not supported" list

## Configuration

Edit `main.zig`:

```zig
const ctx = S3Context{
    .allocator = allocator,
    .data_dir = "data",
};

const address = net.Address.parseIp4("0.0.0.0", 9000)
```

## Building

Requires Zig 0.16.0. zs3 uses the `std.Io` APIs introduced in Zig 0.16 and
does not build with Zig 0.15.x.

```bash
zig build                                      # debug
zig build -Doptimize=ReleaseSmall              # smallest native release
zig build -Dtarget=x86_64-linux-musl \
  -Dcpu=baseline -Doptimize=ReleaseSmall       # static Linux (~440KB)
zig build -Doptimize=ReleaseFast               # favor throughput over size
zig build test                               # run tests
```

## Install

Tagged releases ship static musl binaries (`zs3-x86_64-linux-musl`,
`zs3-aarch64-linux-musl`), a macOS ARM64 binary, and a multi-arch image:

```bash
# Docker / Compose (GHCR)
docker run -p 9000:9000 -v zs3-data:/data \
  ghcr.io/lulzx/zs3 --acl=admin:local-access:local-secret

# Static binary
curl -fsSL https://github.com/Lulzx/zs3/releases/latest/download/zs3-x86_64-linux-musl -o zs3
chmod +x zs3 && ./zs3

# Homebrew (see packaging/homebrew/zs3.rb for the tap setup)
brew tap Lulzx/zs3 && brew install zs3
```

`docker build -t zs3 .` builds the image locally with Zig 0.16.0.

### Compose

Drop-in replacement for a MinIO service in `docker-compose.yml`:

```yaml
services:
  object-storage:
    image: ghcr.io/lulzx/zs3
    command: ["--acl=admin:local-access:local-secret"]
    ports:
      - "9000:9000"
    volumes:
      - object-data:/data

volumes:
  object-data:
```

Full migration guide: [docs/replace-minio.md](docs/replace-minio.md).

## Testing

```bash
zig build test                  # 51 unit tests
python3 test_bootstrap.py       # two-node bootstrap discovery
python3 test_replication.py     # four-node replication suite (stdlib only)
python3 test_client.py          # 28/28 integration tests (stdlib only)
python3 test_comprehensive.py   # 87/87 boto3 tests (standalone)
python3 test_new.py             # ETags, checksums, trailers, presigned URLs, snapshot/clone
python3 test_foreign.py         # foreign-tree test: LIST/GET/HEAD/range + rclone check
./zs3 --distributed && \
python3 test_comprehensive.py   # 92/92 boto3 tests (distributed)
```

Requires `pip install boto3` for comprehensive tests.

Client compatibility smoke test (aws-cli, boto3, and rclone):

```bash
./scripts/verify-clients.sh
```

## Benchmark

### vs RustFS (100 iterations)

| Operation | zs3 | RustFS | Speedup |
|-----------|-----|--------|---------|
| PUT 1KB | 0.46ms | 12.57ms | **27x** |
| PUT 1MB | 0.99ms | 55.74ms | **56x** |
| GET 1KB | 0.32ms | 10.01ms | **31x** |
| GET 1MB | 0.43ms | 53.22ms | **124x** |
| LIST | 0.86ms | 462ms | **537x** |
| DELETE | 0.34ms | 11.52ms | **34x** |

### Concurrent (50 workers, 1000 requests)

| Metric | zs3 | RustFS | Advantage |
|--------|-----|--------|-----------|
| Throughput | 5,000+ req/s | 174 req/s | **29x** |
| Latency (mean) | 8.8ms | 277ms | **31x faster** |

### vs Garage (100 iterations)

[Garage](https://garagehq.deuxfleurs.fr/) is another S3-compatible server (single-node, default config, lmdb backend, replication_factor=1).

| Operation | zs3 | Garage | Speedup |
|-----------|-----|--------|---------|
| PUT 1KB | 1.05ms | 11.12ms | **11x** |
| PUT 1MB | 4.95ms | 71.54ms | **14x** |
| GET 1KB | 1.44ms | 9.47ms | **7x** |
| GET 1MB | 4.92ms | 55.81ms | **11x** |
| LIST | 4.68ms | 35.69ms | **8x** |
| DELETE | 1.58ms | 12.07ms | **8x** |

### Concurrent vs Garage (50 workers, 1000 requests)

| Metric | zs3 | Garage | Advantage |
|--------|-----|--------|-----------|
| Throughput | 4,326 req/s | 147 req/s | **29x** |
| Latency (mean) | 11.0ms | 324ms | **29x faster** |

Run your own: `python3 benchmark.py`

To bench against Garage, spin it up with the bundled compose file:

```sh
cd bench && ./init-garage.sh
# prints access_key_id / secret_access_key for the created bench-key
python3 ../benchmark.py --only zs3,garage \
  --garage-access-key <ID> --garage-secret-key <SECRET>
```

`--only` accepts any combo of `zs3,rustfs,garage`.

## Limits

| Limit | Value |
|-------|-------|
| Max header size | 8 KB |
| Max body size | 5 GB |
| Max key length | 1024 bytes |
| Bucket name | 3-63 chars |

The 1024-byte key limit matches S3. Because objects are stored as plain
files, a single `/`-separated key component is also limited to 255 bytes
(filesystem filename limit), and the full path (`data_dir` + bucket + key)
must fit the platform's `PATH_MAX` (1024 on macOS). Keys beyond those
filesystem limits are rejected with a clean `400 KeyTooLong` error rather
than failing to store.

## Security

- Full SigV4 signature verification (case-insensitive header matching)
- Input validation on bucket names, object keys, and upload IDs
- Path traversal protection (blocks `..` in keys, rejects absolute paths, validates multipart upload IDs)
- XML escaping on all user-supplied values in responses (keys, prefixes, continuation tokens, max-keys)
- Query parameter boundary checking (no substring false positives)
- Request size limits (8KB headers, 5GB body, 1024-byte keys)
- No shell commands, no eval, no external network calls
- Runtime safety checks enabled on all network-facing code
- Single file, easy to audit

TLS not included. zs3 speaks plain HTTP; terminate TLS in a reverse proxy
(see [Deployment](docs/deployment.md) for Caddy/nginx configs). Presigned URLs
embed the endpoint scheme, so generate them against the public https:// URL —
signatures verify the same behind the proxy.

## License

[WTFPL](LICENSE) - Read it, fork it, break it.
