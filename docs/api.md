# API Reference

zs3 implements a subset of the AWS S3 REST API with SigV4 authentication.

## Authentication

Header auth (all requests):

```
Authorization: AWS4-HMAC-SHA256
  Credential={access_key}/{date}/{region}/s3/aws4_request,
  SignedHeaders={signed_headers},
  Signature={signature}
```

Required headers:
- `Authorization` - SigV4 signature
- `x-amz-date` - Request timestamp (ISO 8601)
- `x-amz-content-sha256` - SHA256 hash of request body
- `Host` - Server hostname

Query-string SigV4 (presigned URLs) is also accepted: `X-Amz-Algorithm`,
`X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`, `X-Amz-SignedHeaders`,
`X-Amz-Signature`. Expiry is enforced against the server clock. Generate with
any SDK (`generate_presigned_url` with `signature_version='s3v4'`); use for
browser direct-uploads and share links.

## Bucket Operations

### ListBuckets

```
GET /
```

Returns XML list of all buckets.

### CreateBucket

```
PUT /{bucket}
```

Creates a new bucket. Bucket names must be 3-63 characters, alphanumeric, hyphens, and dots only.

### DeleteBucket

```
DELETE /{bucket}
```

Deletes an empty bucket. Returns 409 if bucket is not empty.

## Object Operations

### PutObject

```
PUT /{bucket}/{key}
```

Uploads an object. Creates parent directories as needed.

Request headers honored:
- `Content-Type` - stored and returned on GET/HEAD (default `binary/octet-stream`)
- `x-amz-meta-*` - user metadata, returned on GET/HEAD
- `x-amz-checksum-*` - accepted, stored, echoed back (validated by SDKs on
  full GETs; omitted from 206 range responses, which describe a byte range,
  not the whole object)
- `x-amz-content-sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD[-TRAILER...]` -
  AWS chunked transfer decoding, including checksum-trailer variants

Response headers:
- `ETag` - quoted lowercase hex MD5 of the object content (so `md5sum`,
  `aws s3 sync`, and `rclone check` agree)

### CopyObject

```
PUT /{bucket}/{key}
x-amz-copy-source: /{src-bucket}/{src-key}   (URL-encoded, ?versionId= ignored)
x-amz-metadata-directive: COPY | REPLACE     (default COPY)
```

Server-side copy. Powers `aws s3 mv/sync`, `rclone move`, and the Terraform
S3 backend. With `COPY`, the destination inherits the source's Content-Type
and metadata; with `REPLACE`, the request's headers are used instead.
Returns `CopyObjectResult` XML with the new ETag.

### GetObject

```
GET /{bucket}/{key}
```

Downloads an object.

Supports range requests:
```
Range: bytes=0-1023
```

Response: 206 Partial Content with `Content-Range` header.

### HeadObject

```
HEAD /{bucket}/{key}
```

Returns object metadata without body.

Response headers:
- `Content-Length` - Object size in bytes

### DeleteObject

```
DELETE /{bucket}/{key}
```

Deletes an object. Returns 204 even if object doesn't exist.

### ListObjectsV2

```
GET /{bucket}?list-type=2
```

Query parameters:
- `prefix` - Filter by key prefix
- `delimiter` - Group keys by delimiter (typically `/`)
- `max-keys` - Maximum results (default 1000)
- `continuation-token` - Pagination token

Response: XML with `Contents` and `CommonPrefixes` elements.

## Multipart Upload

### InitiateMultipartUpload

```
POST /{bucket}/{key}?uploads
```

Returns XML with `UploadId`.

### UploadPart

```
PUT /{bucket}/{key}?uploadId={id}&partNumber={n}
```

Uploads a part. Part numbers start at 1.

Response headers:
- `ETag` - quoted lowercase hex MD5 of the part content

### UploadPartCopy

```
PUT /{bucket}/{key}?uploadId={id}&partNumber={n}
x-amz-copy-source: /{src-bucket}/{src-key}
x-amz-copy-source-range: bytes={first}-{last}   (optional)
```

Copies (a byte range of) an existing object into a multipart part. Returns
`CopyPartResult` XML. Missing upload IDs return `NoSuchUpload`;
unsatisfiable ranges return `416 InvalidRange`.

### ListParts

```
GET /{bucket}/{key}?uploadId={id}
```

Returns `ListPartsResult` XML with part numbers, ETags, and sizes.

### CompleteMultipartUpload

```
POST /{bucket}/{key}?uploadId={id}
```

Assembles parts into final object. Request body contains part list (ignored - all parts are assembled in order).

### AbortMultipartUpload

```
DELETE /{bucket}/{key}?uploadId={id}
```

Cancels upload and deletes uploaded parts.

## Versioning

`PUT /{bucket}?versioning` with `<VersioningConfiguration><Status>Enabled|Suspended</Status></VersioningConfiguration>`;
`GET /{bucket}?versioning` returns it (an empty element when never set).

With versioning enabled:

- Every PUT, CopyObject and CompleteMultipartUpload returns
  `x-amz-version-id`. The previous current object moves to
  `.zs3versions/<key>.v/<version-id>` with its metadata sidecar.
- Objects written before versioning was enabled are version `null`.
- `DELETE /{bucket}/{key}` adds a delete marker (`x-amz-delete-marker: true`
  plus its `x-amz-version-id`); GET/HEAD then return `404 NoSuchKey` with
  `x-amz-delete-marker: true`.
- `?versionId=` on GET, HEAD, DELETE, and in `x-amz-copy-source` selects a
  version. DELETE with a version id removes it permanently and promotes the
  next newest version; deleting the newest delete marker restores the key.
  A missing version is `404 NoSuchVersion`; GET on a delete marker is `405`.
- `GET /{bucket}?versions` (ListObjectVersions) supports `prefix`,
  `delimiter`, `max-keys`, `key-marker`, `version-id-marker`.
- `POST /{bucket}?delete` accepts `<VersionId>` per object and reports
  `DeleteMarker` / `DeleteMarkerVersionId`.
- Suspended: new writes are the `null` version and overwrite it in place;
  existing versioned objects are kept.
- A bucket with stored versions or delete markers is `409 BucketNotEmpty`.

Distributed mode refuses to enable versioning (`501 NotImplemented`).

## Tagging

- `PUT/GET/DELETE /{bucket}/{key}?tagging` with the standard `<Tagging>`
  body; `x-amz-tagging: k=v&k2=v2` on PUT/CopyObject/initiate multipart;
  `x-amz-tagging-directive: COPY|REPLACE` on CopyObject; GET/HEAD return
  `x-amz-tagging-count`.
- `PUT/GET/DELETE /{bucket}?tagging` for bucket tags (`404 NoSuchTagSet`
  when unset).
- Up to 10 tags, keys 1-128 and values 0-256 characters, unique keys; else
  `400 InvalidTag`.

## ACLs

Canned ACLs only. `x-amz-acl` on CreateBucket, PutObject, CopyObject and
initiate multipart, or `PUT /{bucket}[/{key}]?acl` with either the header or
an `AccessControlPolicy` body (reduced to its `AllUsers` grants; grants to
other accounts are `400`). `GET ?acl` returns the policy with the owner's
`FULL_CONTROL` plus `AllUsers` `READ`/`WRITE` grants when public.

| ACL | Unsigned requests may |
|-----|-----------------------|
| `private` (default) | nothing |
| `public-read` | GET/HEAD objects, LIST the bucket |
| `public-read-write` | the above plus PUT/DELETE objects and `?delete` |

An object with `public-read` is readable anonymously even in a private
bucket. Anonymous callers can never create/delete buckets or change
`?acl`, `?versioning`, `?lifecycle`, `?encryption`, or bucket tags. Other
canned values (`authenticated-read`, `bucket-owner-*`, ...) are accepted and
behave as `private`, since every signed request is the owner.

## Lifecycle

`PUT/GET/DELETE /{bucket}?lifecycle` with the standard
`<LifecycleConfiguration>`. The configuration is stored verbatim and
validated on PUT. Supported per rule: `Status`, `Filter` with `Prefix`,
`Tag`, or `And` (or the legacy top-level `Prefix`), `Expiration` (`Days`,
`Date`, or `ExpiredObjectDeleteMarker`), `NoncurrentVersionExpiration`
(`NoncurrentDays`, measured from when the version became noncurrent), and
`AbortIncompleteMultipartUpload` (`DaysAfterInitiation`). `Transition` and
`NoncurrentVersionTransition` are `501 NotImplemented`.

Rules run on a background thread every `--lifecycle-interval-s` seconds
(default 3600). Expiring an object on a versioned bucket adds a delete
marker, exactly like DELETE. `Days: 0` means "on the next pass".

## Server-side encryption

Objects are encrypted at rest as 64KB AES-256-GCM chunks behind a 52-byte
header (format in [security.md](security.md)). The ETag is still the MD5 of
the plaintext; HEAD, LIST and ListObjectVersions report plaintext sizes;
range requests work.

- **SSE-S3**: `x-amz-server-side-encryption: AES256` on PUT, CopyObject or
  initiate multipart, or a bucket default via `PUT /{bucket}?encryption`
  (`GET`/`DELETE` too; `404 ServerSideEncryptionConfigurationNotFoundError`
  when unset). The master key comes from `--sse-key-file`, `ZS3_SSE_KEY`,
  or is generated into `<data-dir>/.zs3/sse.key`.
- **SSE-C**: `x-amz-server-side-encryption-customer-algorithm: AES256`,
  `-customer-key` (base64, 32 bytes), `-customer-key-MD5`. The same headers
  are required on GET/HEAD (`400 InvalidRequest` when missing,
  `403 AccessDenied` for a wrong key), on every UploadPart and on
  CompleteMultipartUpload, and as `x-amz-copy-source-server-side-encryption-customer-*`
  when copying from an SSE-C object. Only the key's MD5 is stored.
- `aws:kms` is `501 NotImplemented`.

Distributed mode refuses encryption (`501 NotImplemented`).

## Error Responses

All errors return XML:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>ErrorCode</Code>
  <Message>Human readable message</Message>
</Error>
```

| Code | Status | Description |
|------|--------|-------------|
| AccessDenied | 403 | Invalid credentials |
| InvalidBucketName | 400 | Bucket name validation failed |
| InvalidKey | 400 | Object key validation failed |
| NoSuchKey | 404 | Object not found |
| NoSuchBucket | 404 | Bucket not found |
| BucketNotEmpty | 409 | Cannot delete non-empty bucket |
| NoSuchUpload | 404 | Multipart upload not found |
| InvalidRange | 416 | Copy source range not satisfiable |
| NoSuchVersion | 404 | Version id does not exist |
| InvalidTag | 400 | Tag set exceeds S3 limits |
| NoSuchTagSet | 404 | Bucket has no tags |
| MalformedACLError | 400 | Unparseable AccessControlPolicy |
| IllegalVersioningConfigurationException | 400 | Status not Enabled/Suspended |
| NoSuchLifecycleConfiguration | 404 | Bucket has no lifecycle rules |
| ServerSideEncryptionConfigurationNotFoundError | 404 | No bucket default encryption |
| InvalidDigest | 400 | SSE-C key MD5 mismatch |
| NotImplemented | 501 | KMS, transitions, versioning/SSE in distributed mode |
| MethodNotAllowed | 405 | HTTP method not supported |
| InternalError | 500 | Server error |

## Snapshots

Content-addressed bucket snapshots live under the `.zs3snapshots/` prefix
(manifests at `.zs3snapshots/<name>.json`, chunks at
`.zs3snapshots/chunks/<hex>`). They are ordinary objects, hidden from normal
LIST responses — LIST with `prefix=.zs3snapshots/` shows them. Created and
consumed with `zs3 snapshot` / `zs3 clone`; see [snapshots.md](snapshots.md).

## Console and metrics

- `GET /_zs3/console` - embedded single-file browser console
  (list/create buckets, browse, upload, download, delete). No server auth on
  the page; the JavaScript signs S3 requests with keys kept in localStorage.
- `GET /metrics` and `GET /_zs3/metrics` - Prometheus text exposition
  (`zs3_requests_total`, `zs3_errors_4xx/5xx`, `zs3_put_bytes`,
  `zs3_get_bytes`, `zs3_uptime_seconds`, `zs3_buckets`, `zs3_known_peers`).
  No auth; safe to scrape.

## Limits

| Limit | Value |
|-------|-------|
| Max header size | 8 KB |
| Max body size | 5 GB |
| Max key length | 1024 bytes |
| Bucket name length | 3-63 characters |
