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
- `ETag` - hash of object content

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
- `ETag` - hash of part content

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
