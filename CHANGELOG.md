# Changelog

All notable changes to zs3 are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and versioning
follows [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-09-09

### Added

- **Bucket versioning.** `?versioning` Enabled/Suspended; every write on a
  versioned bucket returns `x-amz-version-id`, the previous object moves to
  `.zs3versions/<key>.v/`, DELETE adds a delete marker, `?versionId=` on
  GET/HEAD/DELETE/copy-source, ListObjectVersions with pagination and
  delimiters, versioned multi-delete. Pre-versioning objects are the `null`
  version. Standalone mode only.
- **Lifecycle rules.** `?lifecycle` with Expiration (Days/Date/
  ExpiredObjectDeleteMarker), NoncurrentVersionExpiration and
  AbortIncompleteMultipartUpload, filtered by Prefix/Tag/And. A background
  thread applies them every `--lifecycle-interval-s` (default 3600).
- **Object and bucket tagging.** `?tagging` on both, `x-amz-tagging` on
  PUT/Copy/initiate, `x-amz-tagging-directive`, `x-amz-tagging-count`.
- **Canned ACLs.** `x-amz-acl` and `?acl` on buckets and objects.
  `public-read` / `public-read-write` let unsigned requests read (and
  write) objects; configuration stays owner-only. Private deployments keep
  the pre-parse 403 for unsigned requests.
- **Server-side encryption.** SSE-S3 (`AES256` header or bucket default via
  `?encryption`) and SSE-C, as chunked AES-256-GCM files with HKDF
  per-object keys. Plaintext ETags and sizes everywhere, ranges work,
  multipart parts are encrypted on upload. Master key from
  `--sse-key-file`, `ZS3_SSE_KEY`, or generated at `<data-dir>/.zs3/sse.key`.
- **TLS in the snapshot client.** `zs3 snapshot` / `clone` / `snapshots`
  accept `https://` endpoints, verifying against the system CA store, with
  `--ca-file` and `--insecure`. Chunked transfer encoding is decoded and
  S3 error codes are printed, so AWS, MinIO, R2 and friends work as the
  snapshot store. `-Dtls=false` builds without it.
- `test_features.py` (100 checks) and 9 new unit tests.

### Changed

- Multipart uploads now store Content-Type, metadata, tags and ACL from
  CreateMultipartUpload (as S3 does) instead of from CompleteMultipartUpload.
- DeleteObjects honours `<Quiet>` and reports per-object errors.
- The static binary grew from ~450KB to ~840KB (aarch64 musl): ~150KB for
  the features above, ~240KB for the TLS client and X.509 verification.

## [0.2.0] - 2026-09-09

### Added

- **CopyObject + UploadPartCopy.** Server-side copy via `x-amz-copy-source`
  (URL-encoded, `?versionId=` accepted and ignored), with
  `MetadataDirective: COPY|REPLACE`, `x-amz-copy-source-range` for parts,
  `NoSuchUpload`/`416 InvalidRange` errors, and a new `ListParts` API.
  `aws s3 mv/sync` and `rclone move` now work.
- **Presigned URLs.** Query-string SigV4 (`X-Amz-Signature`) with server-side
  expiry enforcement, for direct-upload and share-link flows.
- **Content-Type + user metadata.** Stored per object (sidecar files in
  standalone mode, replicated `.attrs` entries in distributed mode) and
  served on GET/HEAD. Default `binary/octet-stream`.
- **SDK checksums.** `x-amz-checksum-*` accepted, stored, and echoed back;
  `STREAMING-...-TRAILER` chunked variants decoded. Whole-object checksums
  are omitted from 206 range responses, matching S3.
- **`zs3 snapshot` / `zs3 clone` / `zs3 snapshots`.** Content-addressed bucket
  snapshots (BLAKE3 chunks + JSON manifest under `.zs3snapshots/`) with
  upload/download dedup; warm re-clones transfer only the manifest.
  See `docs/snapshots.md`.
- **Embedded console + metrics.** `GET /_zs3/console` serves a single-file
  browser UI (SigV4 in-page, keys in localStorage only); `GET /metrics`
  (and `/_zs3/metrics`) exposes Prometheus counters. CORS preflight
  (`OPTIONS`) answered without auth.
- **Distribution.** `Dockerfile` (multi-arch static), GHCR publish +
  musl/macOS release binaries via `release.yml`, CI via `ci.yml`,
  Homebrew tap template in `packaging/homebrew/`.
- **`--fast` benchmark mode.** fsync-on-write is now the default (see Fixed);
  `--fast`/`--no-fsync` restores the no-fsync fast path.
- **Relaunch notes.** `docs/launch.md`: prepared answers on durability, the
  Garage / `rclone serve s3` comparison, SigV4 correctness, and
  single-file maintainability, for the "turn any directory into an S3
  server" relaunch.

### Changed

- **Live mesh frozen.** Distributed mode stays in the binary but receives no
  new work; `zs3 snapshot` / `zs3 clone` over the content-addressed store is
  the supported way to move data between machines. Decision and reasoning in
  `docs/vision.md` (now current — the snapshot/clone section reflects what
  shipped) and the README.

### Fixed

- **Embedded console completed.** The shipped `console.html` ended mid-script
  (helpers defined, zero UI wiring), so the page rendered but could not list
  buckets, browse, upload, inspect, or delete. The missing application logic
  is now implemented against the existing markup: connection dialog with
  remembered credentials and auto-connect, bucket sidebar + mobile picker,
  create/delete bucket, prefix navigation with breadcrumbs and LIST
  pagination, client-side filter, multi-file upload (file picker and
  drag-drop) with signed `Content-Type`, object inspector (HEAD metadata
  grid, download, copy S3 URI, text/image preview, delete), keyboard
  shortcuts, and theme toggle. Verified headless end-to-end (18/18 checks:
  connect → create → upload → inspect → preview → delete → bucket delete →
  reload auto-connect).

- **fsync-on-write (durability).** Acknowledged PUT/CopyObject/
  multipart-complete/snapshot writes fsync file contents and best-effort
  parent dirs. The old behavior (rename without fsync) is available via
  `--fast`, which the README benchmarks now use.
- **MD5 ETags.** Single-object ETags are the quoted lowercase hex MD5 of the
  content, so `aws s3 sync`, `rclone check`, and local `md5sum` agree —
  including against trees zs3 did not write. (Multipart keeps the composite
  `"md5-of-part-md5s-N"` form.)
- **Request paths are percent-decoded.** Keys with spaces, `+`, `#`, or
  non-ASCII characters are stored under their real names, so `ls` shows what
  you PUT and LIST returns decoded keys. Data dirs written before this change
  keep working via a read fallback (see `docs/deployment.md#migrating-a-pre-020-data-directory`).
- **ListBuckets hides unusable directories.** Only directories with valid
  bucket names are listed; the rest are skipped instead of advertised-then-rejected.
- **Content-Type sniffing for foreign files.** Objects without a stored
  sidecar (files zs3 did not write) get a Content-Type from a small extension
  table instead of `binary/octet-stream`. Explicitly stored types always win.
- **Sidecar/attrs files no longer leak into LIST responses.**
- **Replication origin-death test fixed.** It used the PUT ETag as the blob
  address, which stopped working when single-object ETags became MD5 (the
  mesh addresses blobs by truncated BLAKE3, not MD5), failing
  deterministically. The test now resolves the true content address from
  the origin's CAS dir; replication itself was never broken (113/113 pass).
- **Snapshot system objects hidden** from normal LIST (visible with
  `prefix=.zs3snapshots/`).
- **`test_new.py` no longer hardcodes a developer's absolute binary path.**
  It resolves `zs3` from `$ZS3_BIN` or the repo's `zig-out/bin`, so the CI
  integration job runs the snapshot/clone checks instead of failing on a
  missing file.

## [0.1.0] - 2026-08-09

First release. Distributed mode now replicates across nodes: writes leave
the node that receives them, reads fall back to peers, and a gossip round
repairs the mesh after restarts and partitions.

### Added

- **Distributed namespace replication.** PUT/DELETE/multipart-complete push
  the raw metadata entry (inline data and tombstones included) to all peers
  via `POST /_zs3/meta`. Bucket create/delete propagate via
  `POST /_zs3/bucket[_delete]`. Cross-node GET/LIST after an acknowledged
  write is immediately consistent.
- **Read fallback.** A GET/HEAD miss falls back to `POST /_zs3/meta_get`.
  Blob reads sweep all known peers when provider records are missing.
- **Bootstrap sync.** Joining nodes pull the full index (`GET /_zs3/index`)
  and discover the bootstrap peer's peers, handshaking so links are
  bidirectional.
- **Background replication worker.** Blob replication, DHT announces, and
  bucket-op propagation run on a `PushWorker` thread off the write path, so
  copying to peers no longer adds to write latency. The ~1KB metadata push
  stays synchronous.
- **Peer gossip.** A `--gossip-interval-ms` round (default 30s) pings random
  peers, refreshing `last_seen` and pulling peer lists, so a node that
  restarts with an empty routing table is rebuilt without re-bootstrapping.
- **Address gossip.** `/_zs3/peers` entries now carry a full
  `"addr":"ip:port"` field. The port-only form is kept as a fallback.
- **Clean 4xx errors for filesystem-size limits.** Keys that can't fit a
  filesystem (`NAME_MAX` per component, `PATH_MAX` total) return
  `400 KeyTooLong` in both standalone and distributed modes instead of a
  misleading 500 from `ENAMETOOLONG`.
- **431 for oversized headers, 400 for oversized bodies.** Request headers
  over 8KB get `431`. Bodies over 5GB get `400`. Neither is truncated or
  dropped silently.

### Fixed

- **Bucket resurrection race.** Bucket create/delete are broadcast by
  different nodes at different times, so a late-arriving create could
  resurrect an already-deleted bucket on replicas (flaky `HEAD <bucket>` in
  the replication suite). A per-bucket last-write-wins registry (`BucketOps`,
  persisted in `data_dir/.buckets/`) keeps create/delete timestamps. Peers
  apply only newer ops, and on a tie the delete wins, matching the
  object-metadata tombstone convention.
- **`fetchFromPeer` EINVAL panic on macOS.** A single ~5GB `read()` is
  rejected by macOS with EINVAL and panics `std.Io`. Peer responses now read
  in 16KB chunks.
- **Hung peers can no longer wedge the event loop.** Peer sockets get 5s
  send/receive timeouts, so a hung peer can't deadlock two nodes mid-request.
- **Unauthenticated `/_zs3/` endpoints now validate bucket/key names.**
- **`HeadObject` for directory prefixes.** Directories answer HEAD instead of
  a miss.

### Docs

- Position zs3 as "SQLite for objects": new `docs/vision.md`,
  `docs/replace-minio.md`, `docs/deployment.md` update, and
  `scripts/verify-clients.sh` / `scripts/verify_boto3.py` for reproducing the
  aws-cli / boto3 / rclone compatibility check.

### Tests

- New `test_replication.py`: a four-node suite (113 checks) covering
  cross-node reads, LWW overwrites, delete-then-recreate, multipart,
  pagination, restart catch-up, origin-node death, gossip mesh repair after a
  routing-table wipe, and peer protocol validation. Unit tests cover the
  meta-entry parser.
- Distributed boto3 suite: 71 → 72 passing.
- Regression tests for the `400 KeyTooLong` / `431` / `400` error paths in
  `test_client.py`.
