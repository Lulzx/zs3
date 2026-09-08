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

zs3 speaks plain HTTP. Terminate TLS in a reverse proxy; see
[Deployment](deployment.md) for Caddy and nginx configs.

Presigned URLs embed the endpoint scheme, so generate them against the public
`https://` URL. The signature verifies the same behind the proxy.

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
writer, reader) and there are no bucket policies, no ACLs, and no encryption
at rest. zs3 is built for local development, CI, agent artifacts, self-hosted
backups, and edge appliances. Anything facing untrusted users belongs behind a
real access-control layer.
