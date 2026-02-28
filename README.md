# zs3

S3-compatible storage in ~3K lines of Zig. Zero dependencies. Optional distributed mode.

## Why

Most S3 usage is PUT, GET, DELETE, LIST with basic auth. You don't need 200k lines of code for that.

| | zs3 | RustFS | MinIO |
|---|-----|--------|-------|
| Lines | ~3,000 | ~80,000 | 200,000 |
| Binary | 360KB | ~50MB | 100MB |
| RAM idle | 3MB | ~100MB | 200MB+ |
| Dependencies | 0 | ~200 crates | many |

## What it does

**Standalone Mode:**
- Full AWS SigV4 authentication (works with aws-cli, boto3, any SDK)
- PUT, GET, DELETE, HEAD, LIST (v2)
- HeadBucket for bucket existence checks
- DeleteObjects batch operation
- Multipart uploads for large files
- Range requests for streaming/seeking (RFC 7233 compliant suffix ranges)
- HTTP 100-continue support (boto3 compatible)
- AWS chunked transfer encoding support
- ~360KB static binary

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
- Pre-signed URLs, object tagging, encryption
- Anything you'd actually need a cloud provider for

If you need these, use MinIO or AWS.

## Quick Start

```bash
zig build -Doptimize=ReleaseFast -Dacl-list="admin:minioadmin:minioadmin"
./zig-out/bin/zs3
```

Server listens on port 9000, stores data in `./data`.

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

Works with any S3 SDK:

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

- Local dev (replacing localstack/minio)
- CI artifact storage
- Self-hosted backups
- Embedded/appliance storage
- Learning how S3 actually works

## When NOT to use this

- Production with untrusted users
- Anything requiring durability guarantees beyond "it's on your disk"
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

Requires Zig 0.15+.

```bash
zig build                                    # debug
zig build -Doptimize=ReleaseFast             # release (~360KB)
zig build -Dtarget=x86_64-linux-musl         # cross-compile
zig build test                               # run tests
```

## Testing

```bash
zig build test                  # ~30 unit tests
python3 test_client.py          # 24 integration tests (stdlib only)
python3 test_comprehensive.py   # 66 boto3 tests (standalone) / 71 (distributed)
```

Requires `pip install boto3` for comprehensive tests.

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

Run your own: `python3 benchmark.py`

## Limits

| Limit | Value |
|-------|-------|
| Max header size | 8 KB |
| Max body size | 5 GB |
| Max key length | 1024 bytes |
| Bucket name | 3-63 chars |

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

TLS not included. Use a reverse proxy (nginx, caddy) for HTTPS.

## License

[WTFPL](LICENSE) - Read it, fork it, break it.
