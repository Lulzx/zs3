# Architecture

zs3 is a single-file HTTP server implementing the S3 REST API.

## Overview

```
┌─────────────────────────────────────────────────┐
│                    main()                       │
│              (connection loop)                  │
└─────────────────────┬───────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────┐
│              handleConnection()                 │
│         (parse request, write response)         │
└─────────────────────┬───────────────────────────┘
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
┌──────────────────┐    ┌──────────────────┐
│   SigV4.verify() │    │     route()      │
│  (authenticate)  │    │(dispatch handler)│
└──────────────────┘    └────────┬─────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  handlePutObject│    │ handleGetObject │    │     ...         │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Components

### S3Context

Holds configuration and provides path helpers.

```zig
const S3Context = struct {
    allocator: Allocator,
    data_dir: []const u8,
    access_key: []const u8,
    secret_key: []const u8,

    fn bucketPath(self, allocator, bucket) ![]const u8
    fn objectPath(self, allocator, bucket, key) ![]const u8
};
```

### Request/Response

Simple HTTP/1.1 parsing and serialization.

```zig
const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: StringHashMap,
    body: []const u8,
};

const Response = struct {
    status: u16,
    headers: ArrayList(Header),
    body: []const u8,
};
```

### SigV4

AWS Signature Version 4 implementation.

```
1. Parse Authorization header
2. Build canonical request (method, path, query, headers, payload hash)
3. Build string to sign (algorithm, timestamp, scope, canonical hash)
4. Derive signing key (HMAC chain: secret → date → region → service → request)
5. Calculate signature (HMAC of string to sign)
6. Compare with provided signature
```

### Handlers

Each S3 operation has a handler function that:
1. Validates input
2. Performs filesystem operations
3. Builds XML response

## Storage Layout

```
data/
├── bucket1/
│   ├── file.txt
│   └── folder/
│       └── nested.txt
├── bucket2/
│   ├── report.pdf
│   ├── report.pdf.zs3attrs      # Content-Type, x-amz-meta-*, tags, ACL,
│   │                            # version id, SSE state (only when needed)
│   ├── .zs3bucket/              # acl, versioning, tagging, lifecycle.xml,
│   │                            # encryption.xml, sse-used marker
│   └── .zs3versions/
│       └── report.pdf.v/
│           ├── 18d3...29d9      # older version + its .zs3attrs
│           └── 18d3...31ab.deletemarker
├── .zs3/
│   ├── sse.key                  # generated SSE-S3 master key (0600)
│   └── object-acls              # marker: some object has a public ACL
└── .uploads/
    └── {upload_id}/
        ├── 1
        ├── 2
        ├── .meta                # bucket, key, SSE mode
        └── .attrs               # attributes sent at initiate
```

- Buckets are directories
- Objects are files; the current version stays at its plain path
- Nested keys create nested directories
- Multipart uploads stored in `.uploads/` with metadata
- `.zs3bucket/`, `.zs3versions/` and `*.zs3attrs` are hidden from LIST

## Memory Management

zs3 uses arena allocation per request:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
```

All allocations during request handling use the arena. When the request completes, everything is freed at once.

## Background work

A lifecycle thread wakes every `--lifecycle-interval-s` seconds, parses each
bucket's `lifecycle.xml`, and expires objects, noncurrent versions, delete
markers and stale uploads. It only renames and unlinks, which are atomic, so
it shares no locks with the request loop.

## Concurrency

zs3 is single-threaded. Connections are handled sequentially.

For concurrent access, the filesystem provides isolation - each request opens/closes files independently.

## Error Handling

Errors are caught at the handler level and converted to S3 XML error responses:

```zig
route(ctx, alloc, &req, &res) catch |err| {
    sendError(&res, 500, "InternalError", "Internal server error");
};
```

Individual handlers return specific errors (404, 400, etc.) via `sendError()`.
