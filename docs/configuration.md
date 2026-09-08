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
| `--help`, `-h` | | Print usage |

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
`AWS_SECRET_ACCESS_KEY`), `--region=R` (default `us-east-1`), and
`--chunk-bytes=N` (default 4MB). See [snapshots.md](snapshots.md).

## Compile-time limits

Constants at the top of `main.zig`:

```zig
const MAX_HEADER_SIZE = 8 * 1024;              // 8 KB
const MAX_BODY_SIZE = 5 * 1024 * 1024 * 1024;  // 5 GB
const MAX_KEY_LENGTH = 1024;                   // bytes
const MAX_BUCKET_LENGTH = 63;                  // characters
```

## TLS

zs3 serves plain HTTP. Terminate TLS in a reverse proxy; [deployment.md](deployment.md)
has Caddy and nginx configs.
