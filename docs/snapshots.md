# Snapshots and clone

`zs3 snapshot` turns a bucket into a content-addressed manifest. `zs3 clone`
materializes a manifest into a directory, downloading only the blocks the
local cache lacks. It is git-clone shaped: repeat clones and re-snapshots
transfer deltas, not everything.

## Commands

```bash
# Record bucket "artifacts" as snapshot "v1" (talks to localhost:9000 by default)
zs3 snapshot --bucket=artifacts --name=v1

# Materialize it somewhere else (possibly another machine)
zs3 clone --bucket=artifacts --name=v1 --dest=./v1

# List snapshots in a bucket
zs3 snapshots --bucket=artifacts
```

Flags (also read from the environment):

| Flag | Env | Default |
|---|---|---|
| `--endpoint=URL` | `ZS3_ENDPOINT` | `http://127.0.0.1:9000` |
| `--bucket=NAME` | | (required) |
| `--name=NAME` | | (required) |
| `--dest=DIR` | | (required for clone) |
| `--cache=DIR` | | `<dest>/.zs3/blobs` |
| `--access-key=K` | `AWS_ACCESS_KEY_ID` | `minioadmin` |
| `--secret-key=S` | `AWS_SECRET_ACCESS_KEY` | `minioadmin` |
| `--region=R` | `AWS_DEFAULT_REGION` | `us-east-1` |
| `--chunk-bytes=N` | | `4194304` (4MB) |

HTTP only. For TLS endpoints, snapshot through a local TLS-terminating
proxy (same story as the server side — see `deployment.md`).

## How it works

Snapshot:

1. LISTs every object in the bucket (skipping the `.zs3snapshots/` prefix,
   so snapshots never snapshot themselves).
2. Splits each object into `--chunk-bytes` chunks, BLAKE3-hashes each chunk,
   and PUTs only chunks the bucket lacks (`HEAD
   .zs3snapshots/chunks/<hex>` first). A second snapshot of mostly-unchanged
   data uploads ~nothing.
3. PUTs the manifest at `.zs3snapshots/<name>.json`.

Clone:

1. GETs the manifest.
2. For each chunk, reuses `<cache>/<xx>/<rest>` when present, otherwise GETs
   `.zs3snapshots/chunks/<hex>` once and caches it. A warm re-clone transfers
   only the manifest.
3. Reassembles each file, verifies its whole-object BLAKE3 hash, and writes
   it atomically. Writes a copy of the manifest to `<dest>/.zs3/manifest.json`.

`.zs3snapshots/` objects are ordinary S3 objects: they replicate in
distributed mode, back up with everything else, and are hidden from normal
LIST responses (a LIST with `prefix=.zs3snapshots/` shows them).

## Manifest format

JSON, stable and hand-parseable:

```json
{
  "version": 1,
  "bucket": "artifacts",
  "name": "v1",
  "created": 1756680000,
  "chunk_bytes": 4194304,
  "objects": [
    {
      "key": "build/app.tar",
      "size": 8388608,
      "hash": "<blake3-32-hex of the whole object>",
      "chunks": ["<blake3-32-hex per chunk>", "..."]
    }
  ]
}
```

Hashes are full 32-byte BLAKE3 in lowercase hex (64 chars) — not the
truncated 20-byte hashes the DHT uses internally. Chunk blobs are addressed
by their own hash, so identical chunks across files (or snapshots) are stored
and transferred once.

## Limits

- Snapshot reads whole objects into memory as it chunks them; very large
  single objects need corresponding RAM on the machine running `snapshot`.
- No locking: snapshotting a bucket that is being written concurrently may
  record a mix of old and new objects.
- Manifests grow with file count (~100 bytes per object plus chunk hashes);
  buckets with millions of tiny files produce large manifests.
