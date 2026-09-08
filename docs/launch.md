# Relaunch notes

Prepared answers for the Show HN thread. The post leads with "turn any
directory into an S3 server" — not "S3 server in Zig." Line count, binary
size, and dependency count are evidence, not the claim. The January 2026
launch led with those and drew one comment, which was the useful part: a
reader who wanted to expose a ZFS array over S3 and had settled on Garage.
That reader is the wedge.

## "Turn any directory into an S3 server"

zs3 is a protocol adapter, not a storage engine. `zs3 --data-dir=/srv/backup`
speaks S3 against a tree it did not create: files written by `mkdir`/`cp`
show up as objects, ETags match local `md5sum`, extension-based
Content-Types are served when no `.attrs` sidecar exists, and buckets that
are just directories are listed only when their names are valid S3 bucket
names. The filesystem stays the source of truth; stop zs3 and the tree is
exactly as it was. This is verified end-to-end by `test_foreign.py`, which
builds a tree with shell tools, starts zs3 afterward, and runs LIST, GET,
HEAD, ranges, and `rclone check` against it.

## Durability

- fsync on file contents (and best-effort parent-directory fsync) before a
  PUT, CopyObject, multipart-complete, or snapshot write is acknowledged.
- Objects are written to temp files and atomically renamed, so a concurrent
  GET never observes a partial object.
- `--fast` disables fsync for benchmarks. Both modes are published in the
  README; on typical SSD hardware the gap is small, and it is labelled.
- What is not claimed: durability across machine loss, or replication. It is
  one machine's disk, honestly.

## Comparison to Garage and `rclone serve s3`

Garage is the closer tool for multi-node: it does quorum replication,
partition tolerance, and multi-site layout. zs3 does not do those things and
is not trying to; the comparison in the README is single-node latency only
(objects are files on disk; there is no LSM tree or metadata index in the
read path). If you need replication_factor > 1, use Garage.

`rclone serve s3` is the closest prior art and a fair choice for many
people. zs3 differs in that it is a single static binary with no Go runtime,
implements SigV4 header and presigned-URL auth with role-based credentials
(reader/writer/admin), CopyObject + UploadPartCopy (which `aws s3 mv/sync`
and `rclone move` use), multipart uploads, SDK checksum validation including
trailer form, a built-in browser console, Prometheus metrics, and stores
metadata that rclone serve s3 does not preserve. It also accepts a tree it
did not create without an index-rebuild step.

## SigV4 correctness

Canonical request → string-to-sign → HMAC-SHA256 chain → constant-time
compare, ~150 lines. Header-based auth, query-string presigned URLs, and the
`STREAMING-*` chunked payload variants (including `-TRAILER` with trailing
`x-amz-checksum-*` headers, which current botocore sends by default on PUT)
are decoded and verified. The supported subset is exercised against aws-cli,
boto3, and rclone on every change (`scripts/verify-clients.sh`), plus
integration suites covering presigned GET/PUT, checksum headers and
trailers, and range-request checksum semantics.

## Single-file maintainability

~7,050 lines across `main.zig`/`acl.zig`/`build.zig`, standard library only,
no dependencies. That number is not the point — it is what makes the
auditability claim testable in one sitting: every line that touches your
bytes is in one file you can read. Versioning, lifecycle, IAM, and bucket
policies are deliberately out of scope; the "what it doesn't do" list is
part of the design.

## Distributed mode

Still in the binary and working, but frozen (see `vision.md`). Live mesh
semantics — DHT, gossip, quorum reads — are a distributed object store's
correctness burden. The supported way to move data between machines is
`zs3 snapshot` / `zs3 clone`: content-addressed manifests of immutable
BLAKE3 digests, deduplicating across hosts, with the filesystem
authoritative throughout.

## Checklist for the thread

- [ ] Submit as "turn any directory into an S3 server"
- [ ] First two hours: stay in the thread
- [ ] Have the `test_foreign.py` transcript ready to paste
- [ ] Have the durability table (both modes) ready to paste
