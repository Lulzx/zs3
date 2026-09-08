# Configuration

zs3 is configured with command-line flags. `zs3 --help` prints the full list.

## Server flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--port=PORT` | 9000 | HTTP port |
| `--data-dir=PATH` | `data` | Directory holding buckets and objects |
| `--acl=LIST` | `admin:minioadmin:minioadmin` | Credentials, see below |
| `--fsync` / `--no-fsync`, `--fast` | fsync on | Durability of acknowledged writes |
| `--distributed`, `-d` | off | Peer-to-peer mode, see [distributed.md](distributed.md) |
| `--bootstrap=PEERS` | none | Comma-separated bootstrap peers |
| `--gossip-interval-ms=N` | 30000 | Peer gossip interval |
| `--sse-key-file=PATH` | `<data-dir>/.zs3/sse.key` | SSE-S3 master key, 64 hex chars (`ZS3_SSE_KEY` env also accepted; generated on first use) |
| `--lifecycle-interval-s=N` | 3600 | How often lifecycle rules are evaluated |
| `--help`, `-h` | | Print usage |

Build-time: `-Dtls=false` drops the https:// client from `zs3 snapshot` /
`zs3 clone` for a ~240KB smaller binary.

The listen address is `0.0.0.0`. To bind localhost only, change
`net.Address.parseIp4` in `main.zig` and rebuild.

## Credentials and roles

Pass credentials at runtime with `--acl=`, or bake them in at build time with
`-Dacl-list=`:

```bash
zs3 --acl="admin:akey:asec,reader:rkey:rsec,writer:wkey:wsec"
```

Each entry is `role:access_key:secret_key`, comma-separated.

| Role | Allowed methods |
|------|-----------------|
| admin | all |
| writer | GET, HEAD, OPTIONS, PUT, POST, DELETE |
| reader | GET, HEAD, OPTIONS |

The default `minioadmin:minioadmin` admin key exists so `aws --endpoint-url`
works out of the box. Replace it anywhere real.

## Snapshot flags

`zs3 snapshot`, `zs3 clone`, and `zs3 snapshots` take `--endpoint=URL` (or
`ZS3_ENDPOINT`), `--bucket=NAME`, `--name=NAME`, `--dest=DIR`, `--cache=DIR`,
`--access-key=K` (or `AWS_ACCESS_KEY_ID`), `--secret-key=S` (or
`AWS_SECRET_ACCESS_KEY`), `--region=R` (default `us-east-1`),
`--chunk-bytes=N` (default 4MB), `--ca-file=PEM` (or `ZS3_CA_FILE`) to trust
a private CA for `https://` endpoints, and `--insecure` to skip certificate
verification. See [snapshots.md](snapshots.md).

## Compile-time limits

Constants at the top of `main.zig`:

```zig
const MAX_HEADER_SIZE = 8 * 1024;              // 8 KB
const MAX_BODY_SIZE = 5 * 1024 * 1024 * 1024;  // 5 GB
const MAX_KEY_LENGTH = 1024;                   // bytes
const MAX_BUCKET_LENGTH = 63;                  // characters
```

## TLS

The server speaks plain HTTP. Terminate TLS in a reverse proxy;
[deployment.md](deployment.md) has Caddy and nginx configs. The snapshot
client (`zs3 snapshot` / `clone` / `snapshots`) speaks `https://` natively,
verifying against the system CA store (plus `--ca-file`).
