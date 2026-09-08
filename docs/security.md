# Security and limits

## What zs3 verifies

- Full SigV4 signature verification, header and presigned query-string forms,
  with case-insensitive header matching
- Bucket names, object keys, and multipart upload IDs are validated on input
- Path traversal is blocked: `..` in keys, absolute paths, and malformed
  upload IDs are rejected
- User-supplied values in XML responses (keys, prefixes, continuation tokens,
  max-keys) are escaped
- Query parameters are matched on both boundaries, so `?list-type=2` does not
  match a substring of another parameter
- Runtime safety checks stay enabled on network-facing code
- No shell execution, no eval, no outbound network calls

## TLS

The server speaks plain HTTP. Terminate TLS in a reverse proxy.
[Deployment](deployment.md) has Caddy and nginx configs. Zig's standard
library has a TLS client but no TLS server, and zs3 has no dependencies, so
this stays a proxy job.

Presigned URLs embed the endpoint scheme, so generate them against the public
`https://` URL. The signature verifies the same behind the proxy.

The snapshot client connects to `https://` endpoints with `std.crypto.tls`,
verifying the certificate chain against the system CA store (and
`--ca-file`) and the hostname. `--insecure` disables both; use it only for
throwaway test servers.

## Encryption at rest

SSE-S3 and SSE-C encrypt objects on disk with AES-256-GCM. File format:

```
"ZS3E" | version 1 | mode (1 = SSE-S3, 2 = SSE-C) | 2 reserved bytes
chunk size u32 LE (65536) | 32-byte salt | 8-byte nonce base      = 52 bytes
then per 64KB chunk: ciphertext || 16-byte tag
  nonce = nonce base || chunk index (u32 LE), AAD = the 52-byte header
```

The per-object key is HKDF-SHA256(master or customer key, salt, "zs3-sse-v1"),
so no two objects share a key and nonces cannot repeat across objects. Every
chunk is authenticated; a flipped byte fails the GET rather than returning
garbage. Chunking keeps range reads and multipart assembly streaming.

The SSE-S3 master key is 32 random bytes stored as hex in
`<data-dir>/.zs3/sse.key` (mode 0600) unless `--sse-key-file` or
`ZS3_SSE_KEY` supplies one. Losing it makes every SSE-S3 object
unreadable; back it up separately from the data directory if the threat
model is "someone walks off with the disk". SSE-C keys are never written to
disk: only their MD5 is stored, to recognise the right key on GET. Multipart
parts are encrypted on upload, so nothing sits in `.uploads/` in the clear.

Encryption does not change the ETag (still the plaintext MD5) or the
metadata sidecar, which stays readable.

## Public access

Canned ACLs `public-read` and `public-read-write` let unsigned requests read
(and, for the latter, write) objects. Unsigned requests are still rejected
before the body is read unless the bucket has an ACL file or an object ACL
has ever been set in the data directory, so private deployments keep the
early 403. Anonymous callers can never touch bucket configuration or create
and delete buckets.

## Limits

| Limit | Value |
|-------|-------|
| Max header size | 8 KB |
| Max body size | 5 GB |
| Max key length | 1024 bytes |
| Bucket name | 3-63 chars |

Requests over the header limit get `431`, over the body limit `400`.

The 1024-byte key limit matches S3. Because objects are stored as plain files,
one `/`-separated key component is also limited to 255 bytes (the filesystem
filename limit), and the full path (`data_dir` + bucket + key) must fit the
platform's `PATH_MAX`, which is 1024 on macOS. Keys past those limits get a
`400 KeyTooLong` instead of a failed store.

## Not for untrusted users

The default credentials are `minioadmin:minioadmin`. Roles are coarse (admin,
writer, reader), ACLs are canned only, and there are no bucket policies or
IAM. zs3 is built for local development, CI, agent artifacts, self-hosted
backups, and edge appliances. Anything facing untrusted users belongs behind a
real access-control layer.
