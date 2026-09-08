# Benchmarks

Numbers from `benchmark.py` on Apple Silicon, macOS, sequential unless the
table says otherwise. Reproduce with `python3 benchmark.py`, or `--only` with
any combination of `zs3,rustfs,garage`.

The comparison tables were taken with `zs3 --fast` (fsync off). See
[Durability](#durability) below for what the default costs.

## vs RustFS (100 iterations)

| Operation | zs3 | RustFS | Speedup |
|-----------|-----|--------|---------|
| PUT 1KB | 0.46ms | 12.57ms | 27x |
| PUT 1MB | 0.99ms | 55.74ms | 56x |
| GET 1KB | 0.32ms | 10.01ms | 31x |
| GET 1MB | 0.43ms | 53.22ms | 124x |
| LIST | 0.86ms | 462ms | 537x |
| DELETE | 0.34ms | 11.52ms | 34x |

Concurrent (50 workers, 1000 requests):

| Metric | zs3 | RustFS |
|--------|-----|--------|
| Throughput | 5,000+ req/s | 174 req/s |
| Latency (mean) | 8.8ms | 277ms |

## vs Garage (100 iterations)

[Garage](https://garagehq.deuxfleurs.fr/) run single-node, default config,
lmdb backend, `replication_factor=1`.

| Operation | zs3 | Garage | Speedup |
|-----------|-----|--------|---------|
| PUT 1KB | 1.05ms | 11.12ms | 11x |
| PUT 1MB | 4.95ms | 71.54ms | 14x |
| GET 1KB | 1.44ms | 9.47ms | 7x |
| GET 1MB | 4.92ms | 55.81ms | 11x |
| LIST | 4.68ms | 35.69ms | 8x |
| DELETE | 1.58ms | 12.07ms | 8x |

Concurrent (50 workers, 1000 requests):

| Metric | zs3 | Garage |
|--------|-----|--------|
| Throughput | 4,326 req/s | 147 req/s |
| Latency (mean) | 11.0ms | 324ms |

To bench against Garage, start it with the bundled compose file:

```sh
cd bench && ./init-garage.sh
# prints access_key_id / secret_access_key for the created bench-key
python3 ../benchmark.py --only zs3,garage \
  --garage-access-key <ID> --garage-secret-key <SECRET>
```

## Durability

zs3 fsyncs file contents, and parent directories where it can, before
acknowledging PUT, CopyObject, multipart-complete, and snapshot writes. The
atomic rename means a concurrent GET reads either the old object or the new
one, not a partial file. The
fsync means an acknowledged write survives a crash or power loss.

`--fast` (alias `--no-fsync`) skips the fsync. Both modes on the same machine,
100 iterations:

| Operation | `--fast` (no fsync) | default (fsync) |
|-----------|--------------------:|----------------:|
| PUT 1KB   | 0.59ms | 0.59ms |
| PUT 64KB  | 0.68ms | 0.74ms |
| PUT 1MB   | 2.99ms | 3.05ms |
| GET 1KB   | 0.39ms | 0.37ms |
| GET 1MB   | 2.00ms | 2.05ms |
| DELETE    | 0.36ms | 0.37ms |

On this hardware the durable default costs single-digit percent, within noise
for small PUTs and reads. Disks with slow fsync (spinning rust, some NFS
mounts) will show a wider gap. Reproduce with `python3 benchmark.py --only zs3`
against a server started with and without `--fast`.
