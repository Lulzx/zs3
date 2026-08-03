# Replace MinIO in Docker Compose with one static binary

This guide replaces a local-development MinIO service with zs3 while keeping
the same S3 endpoint, credentials, bucket names, and client libraries.

zs3 implements a deliberately small S3 subset. Check the
[API reference](api.md) before migrating: versioning, lifecycle policies,
bucket ACLs, presigned URLs, object tags, and server-side encryption are not
supported. This replacement is intended for local development, CI, agent
artifacts, and edge workloads—not as a production MinIO migration.

## 1. Build the Linux binary

Build for the architecture used by Docker. For an x86-64 image:

```bash
zig build -Dtarget=x86_64-linux-musl \
  -Dcpu=baseline -Doptimize=ReleaseSmall
cp zig-out/bin/zs3 ./zs3
```

The resulting executable is statically linked and under 360KB. For an ARM64
image, change the target to `aarch64-linux-musl`.

Add a two-line `Dockerfile.zs3` next to your Compose file:

```dockerfile
FROM scratch
COPY zs3 /zs3
ENTRYPOINT ["/zs3"]
```

## 2. Replace the service

A typical local MinIO service looks like this:

```yaml
services:
  object-storage:
    image: minio/minio
    command: server /data --console-address :9001
    environment:
      MINIO_ROOT_USER: local-access
      MINIO_ROOT_PASSWORD: local-secret
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - object-data:/data
```

Replace it with:

```yaml
services:
  object-storage:
    build:
      context: .
      dockerfile: Dockerfile.zs3
    command:
      - --data-dir=/data
      - --acl=admin:local-access:local-secret
    ports:
      - "9000:9000"
    volumes:
      - object-data:/data

volumes:
  object-data:
```

The application endpoint remains `http://object-storage:9000` from another
Compose service, or `http://localhost:9000` from the host. Remove MinIO's port
9001: zs3 has no admin console.

`--acl` entries use `role:access_key:secret_key`. Comma-separate entries for
multiple credentials. Do not commit production secrets to a Compose file.

## 3. Start and verify

```bash
docker compose up -d --build object-storage
export ZS3_ENDPOINT=http://localhost:9000
export ZS3_ACCESS_KEY=local-access
export ZS3_SECRET_KEY=local-secret
./scripts/verify-clients.sh
```

The check creates an isolated bucket for each client, then exercises create,
PUT, GET, LIST/HEAD, DELETE, and bucket cleanup with:

| Client | Interface under test |
|---|---|
| AWS CLI | `s3api` |
| boto3 | Python S3 client |
| rclone | S3 provider `Other` |

Each tool must be installed locally. The script exits nonzero on the first
incompatibility and always removes its temporary local files.

## 4. Keep application configuration unchanged

Continue using path-style S3 configuration:

```text
endpoint    http://object-storage:9000
access key  local-access
secret key  local-secret
region      us-east-1
```

If an SDK defaults to virtual-hosted bucket URLs, force path-style addressing.
The boto3 equivalent is `Config(s3={"addressing_style": "path"})`.

## Roll back

Stop the service, restore the original MinIO service definition, and start it
again. Although standalone zs3 stores objects as ordinary files beneath the
data directory, treat the volume formats as different: use an S3 client such as
rclone to copy data between running servers rather than mounting the same
volume into both.
