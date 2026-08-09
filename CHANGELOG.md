# Changelog

All notable changes to zs3 are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and versioning
follows [Semantic Versioning](https://semver.org/).

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
