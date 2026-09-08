# zs3 documentation

## Using it

- [Configuration](configuration.md): flags, credentials and roles, limits
- [API reference](api.md): the S3 subset zs3 implements, request by request
- [Snapshots and clone](snapshots.md): content-addressed bucket copies
- [Deployment](deployment.md): systemd, Docker, reverse proxy, backup
- [Replace MinIO in Docker Compose](replace-minio.md): step-by-step migration
- [Security and limits](security.md): what is verified, what is not, size caps
- [Benchmarks](benchmarks.md): vs RustFS and Garage, fsync cost
- [Testing](testing.md): unit, integration, and client-compatibility suites

## How it works

- [Architecture](architecture.md): request path, storage layout, memory model
- [Conditional writes](conditional-writes.md): turning PUT into compare-and-swap
- [Distributed mode](distributed.md): the frozen peer-to-peer mode

## Direction

- [Vision](vision.md): what zs3 is for and what it will not become
- [Roadmap](roadmap.md): milestones, ordered by what unblocks what
- [Relaunch notes](launch.md): prepared answers for the Show HN thread
