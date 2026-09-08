# Distributed mode

**Status: frozen.** Distributed mode works and is included in the binary, but takes
no new development. Live replication, DHT discovery, and gossip carry the
correctness obligations of a distributed object store, which is not the job
zs3 is built for. Use [snapshots and clone](snapshots.md) to move data between
machines. This page describes the mode as it exists today.

## Running a mesh

```bash
# Node 1
./zs3 --distributed --port=9000

# Node 2, bootstrapping off node 1
./zs3 --distributed --port=9001 --bootstrap=localhost:9000

# Node 3
./zs3 --distributed --port=9002 --bootstrap=localhost:9000,localhost:9001
```

Every node serves the same S3 API. PUT on any node, GET from any node.

## How the namespace stays in sync

Each PUT and DELETE pushes the bucket/key metadata entry, including inline
data for objects under 4KB, to all known peers before acknowledging, so a
cross-node read after an acknowledged write is immediately consistent.

Larger blobs go to `REPLICATION_TARGET` nodes and are announced in the DHT by
a background worker, off the write path. A GET that arrives before replication
finishes falls back to fetching the blob from peers.

A joining node pulls the full index from its bootstrap peers and discovers
their peers. A gossip round every `--gossip-interval-ms` (default 30s)
refreshes liveness and repairs the mesh after a restart or partition.

Conflicts resolve last-write-wins at second granularity. Deletes propagate as
tombstones, so a late-arriving write does not resurrect a deleted key.

## What the mode adds

- Content-addressed storage keyed by BLAKE3 hash, deduplicated across the mesh
- Kademlia DHT for peer and content discovery
- Peer-to-peer transfer with quorum reads
- Inline storage for objects under 4KB
- Block garbage collector with a grace period
- LAN discovery with no configuration

## Storage layout

```
data/
├── .node_id              # persistent 160-bit node identity
├── .cas/                 # content-addressed store
│   └── ab/abc123...blob  # files keyed by BLAKE3 hash
├── .index/               # S3 path -> content hash
│   └── bucket/key.meta
└── bucket/               # standalone mode only
```

## Peer protocol

```bash
curl http://localhost:9000/_zs3/ping           # node health and ID
curl http://localhost:9000/_zs3/peers          # known peers
curl http://localhost:9000/_zs3/providers/HASH # who holds a blob
```
