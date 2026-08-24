# conditional writes in a 360KB object store

*what it takes to turn PUT into a compare-and-swap*

There is a family of protocols that build transactional databases directly on
object storage without any external coordinator. SlateDB does it. Delta and
Iceberg do versions of it. The [protocols themselves are elegant](https://www.bitsxpages.com/p/protocols-for-transactional-usage):
a writer proposes a new manifest, and the store either accepts it or tells the
writer that someone else got there first.

All of them rest on one primitive. The store must be able to reject a write
based on what is already at the key. S3 grew this in 2024 with `If-None-Match: *`,
and the whole design space opened up. Before that, everyone rented DynamoDB
to hold a lock.

I wanted zs3 to speak that primitive. zs3 is an S3-compatible server in a
single 4,300-line Zig file that compiles to a 360KB static binary, and its
whole reason for existing is that you can run it on a laptop, in CI, or on a
box at the edge without a control plane. If a WAL-on-object-storage design
works against real S3, it should work against zs3 too, so you can develop
against something you can read end to end.

This is what implementing that took, and where it is still a weaker guarantee
than the real thing.

## Two headers

The client side is small. There are exactly two operations worth having.

**Create if absent.** `If-None-Match: *` on a PUT. Succeeds only when the key
does not exist. This is how you claim a WAL segment, or a lease, or a
"someone is compacting" marker.

**Compare and swap.** `If-Match: "<etag>"` on a PUT. Succeeds only when the
object still has the ETag you read. This is how you advance a manifest without
clobbering a concurrent writer.

Against zs3 the two look like this from boto3:

```python
# claim seg-0, only if nobody has it
s3.put_object(Bucket='wal', Key='seg-0', Body=b'a', IfNoneMatch='*')
# -> ETag "28d2053309d28531"

s3.put_object(Bucket='wal', Key='seg-0', Body=b'b', IfNoneMatch='*')
# -> 412 PreconditionFailed

# advance it, only if it is still what I read
s3.put_object(Bucket='wal', Key='seg-0', Body=b'c', IfMatch=etag)   # 200
s3.put_object(Bucket='wal', Key='seg-0', Body=b'd', IfMatch=etag)   # 412, etag is stale
```

The header parsing is the least interesting part, and it is still worth getting
right: the value can be `*`, a single quoted ETag, or a comma-separated list of
them, so a match means "any entry in the list, trimmed, equals the current
ETag." Twelve lines. On GET and HEAD the same headers mean something different
again, where an `If-None-Match` hit is a 304 rather than a 412, because that is
a cache revalidation, not a failed write.

Everything hard is on the server.

## Two atomicity problems, not one

A conditional PUT asks the server for two separate guarantees, and it is easy
to ship the first and quietly miss the second.

The first is that the object itself changes atomically. A reader must see the
old bytes or the new bytes, never a prefix of the new ones. Without this, a
crash halfway through a 4MB manifest leaves a truncated manifest at a live key,
and every reader in the cluster parses garbage.

The second is that the check and the write happen together. If the server reads
the current ETag, decides the precondition holds, and then writes, another
request can slip in between those two steps. Both writers get a 200. One of
them silently loses. This is the failure that makes conditional writes worse
than useless: the protocol above them assumes a 200 means exclusive ownership.

### Torn writes: temp file and rename

The first problem has a standard answer, which is to write to a temporary file
in the same directory and `rename` it over the target. POSIX `rename` within a
filesystem is atomic, so a reader that opens the path gets either the old inode
or the new one.

```zig
var af = std.Io.Dir.cwd().createFileAtomic(app_io, path, .{
    .make_path = true,
    .replace = true,
});
defer af.deinit(app_io);
try af.file.writeStreamingAll(app_io, req.body);
try af.replace(app_io);
```

The part worth saying out loud is that objects are not the only thing that
needs this. In distributed mode zs3 also writes content-addressed blobs and a
small `.meta` index entry per key, and a half-written index entry is a worse
outcome than a half-written object, because it corrupts the mapping rather than
one value. All three writes go through the same path now.

`make_path` matters more than it looks. S3 keys are flat strings that zs3 maps
onto nested directories, so `a/b/c.txt` needs `a/b/` to exist before the
temporary file can be created next to the target. Creating the temp file
somewhere else and renaming across directories would break the atomicity
guarantee the moment the data directory spans two filesystems.

### The check-then-write race

The second problem is the interesting one, and zs3 gets to solve it in a way a
larger server cannot.

zs3 handles requests on a single thread. There is a kqueue loop on macOS and an
epoll loop on Linux, and in both of them, one readable connection is dispatched
to `handleConnectionWithStream`, which parses, routes, and answers the request
to completion before the loop looks at the next event. There is a second thread
in distributed mode for background replication and gossip, but it never serves
S3 requests.

That means the check and the write are already indivisible with respect to
every other S3 request. Nothing runs between them, because nothing else runs at
all. The precondition check is a plain function that returns a bool, with no
lock, no CAS loop, and no fsync fence:

```zig
fn checkPutPreconditions(allocator, req, res, path) bool {
    const if_match = req.header("if-match");
    const if_none_match = req.header("if-none-match");
    if (if_match == null and if_none_match == null) return true;

    const existing = existingEtag(allocator, path);
    defer if (existing) |e| allocator.free(e);

    if (if_match) |im| {
        const matches = if (existing) |e| etagListMatches(im, e) else false;
        if (!matches) { sendError(res, 412, "PreconditionFailed", ...); return false; }
    }
    if (if_none_match) |inm| {
        const matches = if (existing) |e| etagListMatches(inm, e) else false;
        if (matches) { sendError(res, 412, "PreconditionFailed", ...); return false; }
    }
    return true;
}
```

Serial execution is usually the thing you apologize for in a server design. Here
it is the whole correctness argument. Linearizability is free when there is one
line.

I wanted to see it rather than reason about it, so: 32 boto3 clients, 32
threads, each doing `If-None-Match: *` on the same fresh key.

```
winners of 32-way race : 1
```

One winner, 31 rejections, every time.

The honest caveat is that the argument holds for one process. Two zs3 processes
pointed at the same data directory would race in the kernel, and nothing in the
code prevents you from doing that. The single-writer property comes from the
deployment shape, not from a lock on disk.

## What it costs

Checking a precondition means knowing the current ETag, and zs3's ETag is a
hash of the content, so a conditional PUT has to read the whole existing object
before it can decide. That is the one real cost, and the code only pays it when
a conditional header is present.

Measured against a `ReleaseFast` build on an M-series laptop, 200 iterations per
row, local loopback:

| operation | p50 | p99 |
|---|---|---|
| PUT 4KiB, unconditional | 0.76 ms | 1.17 ms |
| PUT 4KiB, `If-Match` | 0.70 ms | 1.99 ms |
| PUT 1MiB, unconditional | 1.26 ms | 1.79 ms |
| PUT 1MiB, `If-Match` | 1.45 ms | 1.71 ms |
| GET 1MiB, unconditional | 0.74 ms | 0.94 ms |

At 4KiB the extra read is lost in noise. At 1MiB it costs about 0.2 ms, because
the object was just written and comes back out of the page cache. On a cold
cache, or with objects large enough not to fit in it, that read becomes a real
disk read and the gap widens with size. The design that avoids this is storing
the ETag next to the object as metadata rather than recomputing it, which zs3
does not do yet in standalone mode. In distributed mode it does, because the
`.meta` index already holds the content hash, so the check is an index lookup
and the object is never touched.

For comparison, the same conditional PUT against real S3 is somewhere in the
tens of milliseconds, which is the entire reason the protocols in the article I
linked are shaped the way they are. Round trips are the budget. Locally they
are close to free, which makes zs3 a bad place to discover that your protocol
does six of them.

## Where the ETag is not what you think

Two things about zs3's ETag are worth knowing before you build on it.

It is a 64-bit wyhash of the content, chosen because it is roughly ten times
faster than SHA-256 and the ETag is on the hot path of every PUT. S3's ETag for
a single-part upload is the MD5 of the body, and clients occasionally check
that. Against zs3 that check fails. Nothing in the S3 spec promises MD5, and
multipart ETags never satisfy it anyway, but a client that hardcodes the
assumption will be unhappy.

Sixty-four bits is also fewer than you want if an adversary picks the content.
For compare-and-swap the question is whether a different value collides with
the ETag you are holding, which is 2^-64 per attempt for content you did not
choose, and much better odds for content someone chose on purpose. wyhash is
not collision resistant. If your protocol's safety depends on a stranger not
being able to forge a matching ETag, zs3's ETag is the wrong primitive, and
distributed mode's BLAKE3 content hash is the right one.

## Distributed mode: local CAS, eventual agreement

Distributed zs3 is peer to peer with no leader. Object metadata replicates by
push, and conflicts resolve last write wins at second granularity. Conditional
writes work per node, against that node's local view of the index.

Which means they are not a distributed lock, and it is easy to show it. Two
nodes, one bootstrapping off the other, both trying to claim the same key at
the same instant:

```
node1: won   node2: won
node1 reads: b'node-1'
node2 reads: b'node-2'
```

Both nodes granted exclusive ownership of the same key, to different writers.
Neither is lying, since at the moment each checked, the key was genuinely
absent locally. Replication had not arrived.

Wait for it to arrive and the answer is correct:

```
node1 claim: won
node2 claim 3s later: PreconditionFailed
node1 b'from-1'
node2 b'from-1'
```

So the guarantee in distributed mode is real but narrow: a conditional write is
a compare-and-swap against one node's state, and nodes agree eventually. That
is enough for the case it was built for, which is a replicator writing segments
it already owns and wanting create-only-if-absent as a safety net against its
own retries. It is not enough for leader election, and the second-granularity
LWW clock means two writes in the same second can leave the two nodes
disagreeing indefinitely rather than converging.

Making it enough would mean quorum writes on the metadata path, and a real
clock, and it would mean giving up the property that any node answers any
request immediately without talking to anyone. That is a different product. The
honest position is to document the boundary rather than let a 200 imply more
than it means.

## What this bought

The point of a 360KB object store is not that it is small. It is that the
distance between a protocol you read about and a server you can step through is
about four thousand lines. Conditional writes were 225 lines of that. You can
read all of them in an afternoon and know exactly what your 200 means, which is
a thing I cannot say about any object store I have run in production.

If you are building one of these WAL-on-object-storage designs and you want
something local to develop against that will not quietly hand two writers the
same lock, [zs3 is here](https://github.com/Lulzx/zs3). If you find a case
where it does, that is a bug and I want it.
