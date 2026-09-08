# SQLite for objects

zs3 is the object store you can understand as a file: one static binary for
local development, CI, agents, and the edge.

The category sentence is:

> Local, dev, and edge object storage should be a 500KB binary.

This is not “smaller MinIO.” MinIO is a production storage platform with the
operational surface that implies. zs3 takes the SQLite-shaped position: a
small, inspectable component with a familiar protocol, local ownership, and no
service machinery.

## The product layers

### Now: one file, familiar clients

- Standalone storage is the default.
- The same binary can opt into peer-to-peer distributed mode.
- The supported S3 subset is tested with aws-cli, boto3, and rclone.
- Standalone objects are ordinary files; distributed objects are BLAKE3-addressed
  blobs behind a small path index.

### Now: cloneable artifact history

`zs3 snapshot` and `zs3 clone` move content-addressed snapshots between
machines and agents. A snapshot is a manifest from bucket/key names to
immutable BLAKE3 digests, so copying a workspace reuses blocks already present
at the destination and retains a stable identity for every artifact. Format
and behavior: [snapshots.md](snapshots.md).

### The live mesh is frozen

Distributed mode still works and is still in the binary, but it is frozen:
no new DHT, gossip, quorum-read, or background-replication work. The reason
is scope, not quality. A live mesh that claims replication semantics is a
distributed object store, which is the correctness weight class zs3 was
started to avoid; its design notes would need quorum math, partition
behavior, and conflict-resolution guarantees to be taken seriously. Content
addressing plus an offline `clone` command keeps the interesting half —
immutable digests, dedup, stable artifact identity — while the filesystem
stays the source of truth and the failure modes stay local and legible. If
the mesh earns a future, it comes back as an explicitly scoped feature, not
as an adjective in the README.

### Next: evidence buckets

Evidence buckets will treat provenance as data rather than convention. An
artifact can be stored with the inputs, tool identity, verification result, and
content digest needed to audit it. A verification compiler can then consume a
stable evidence manifest instead of scraping logs.

This is also planned, not part of the current S3 API. The intended invariant is
simple: an evidence record must resolve to immutable bytes and make tampering
detectable.

## What zs3 deliberately does not become

- A full AWS S3 implementation
- A cluster administration suite
- An identity or policy platform
- A replacement for managed, multi-tenant production storage

The roadmap compounds the original advantage—small, auditable, local—rather
than trading it away for feature parity.
