# SQLite for objects

zs3 is the object store you can understand as a file: one static binary for
local development, CI, agents, and the edge.

The category sentence is:

> Local, dev, and edge object storage should be a 360KB binary.

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

### Next: cloneable artifact history

`zs3 clone` will move content-addressed snapshots between machines and agents.
A snapshot is a manifest from bucket/key names to immutable content hashes, so
copying a workspace can reuse blocks already present at the destination and
retain a stable identity for every artifact.

This is a planned public workflow. The current distributed storage layer
already provides content addressing and deduplication, but there is no public
`zs3 clone` command or snapshot manifest format yet.

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
