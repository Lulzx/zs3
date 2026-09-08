# Roadmap

Ordered by what unblocks what. Milestone 1 is the one that matters: it is the
difference between the pitch and the code.

## Positioning

The claim is not "small S3 server in Zig." That is the mechanism. The claim is:

> Turn any directory into an S3 server.

The user is someone who already owns their storage (ZFS array, NAS, NFS mount,
CI volume, edge device) and needs software that expects S3 to talk to it. The
filesystem stays the source of truth; zs3 is a protocol adapter, not a storage
engine.

That framing raises the bar. "zs3 owns its data dir" is a weaker promise than
"zs3 reads a tree it did not create," and several code paths still assume the
former.

## Milestone 0: housekeeping

- [x] Commit the working tree. `main.zig` is modified and `console.html` is
      untracked. (Doing this surfaced a real bug: the committed
      `console.html` ended mid-script — styled markup and signing helpers
      with zero UI wiring, so the shipped console rendered but did nothing.
      The missing application logic is implemented and verified headless
      end-to-end; see the CHANGELOG.)
- [x] Update README and CHANGELOG for fsync, presigned URLs, CopyObject,
      UploadPartCopy, and the embedded console.
- [x] Fix the line-count claim. README says ~4,300; `main.zig` alone is 6,498.
      (Now ~7,050 across `main.zig acl.zig build.zig`, updated again after the
      snapshot/clone work.)

## Milestone 1: make the tagline true

Each item below breaks the "point zs3 at an existing tree" demo.

- [x] **MD5 ETags for single objects.** Six sites compute
      `std.hash.Wyhash.hash(0, ...)`: `main.zig:2947, 3197, 3246, 3328, 3622,
      3757`. `docs/api.md` documents ETag as MD5, and rclone and `aws s3 sync`
      use ETag to decide what needs re-transferring. The multipart composite
      ETag already uses `std.crypto.hash.Md5` (`main.zig:4222`), so the two
      paths disagree with each other as well as with S3.

      Done: every ETag site now uses `md5Etag` (`std.crypto.hash.Md5`).
      Verified by `test_foreign.py` (ETag == local md5sum for files zs3 did
      not write) and `rclone check` against a foreign tree.

      Acceptance: `aws s3 cp` followed by local `md5sum` agree; `rclone check`
      passes against a tree zs3 did not write. — Met.

- [x] **Filter ListBuckets through `isValidBucketName`.** `handleListBuckets`
      skips non-directories and dotfiles, nothing else. A directory named
      `Backups` or `media_archive` is listed as a bucket and then rejected by
      every operation against it, because `isValidBucketName` (`main.zig:2217`)
      forbids uppercase and underscores. Hiding invalid directories is the
      honest default; normalizing them is the alternative.

      Done: hiding, per the recommendation (`main.zig` `handleListBuckets`).

- [x] **Content-type sniffing by extension** when no `.attrs` sidecar exists.
      Pre-existing files all serve as `binary/octet-stream`
      (`DEFAULT_CONTENT_TYPE`, `main.zig:2926`). A short extension table covers
      the common cases.

      Done: `sniffContentType`; sidecar metadata still takes precedence.

- [x] **Test against a foreign directory tree.** Create files with `mkdir` and
      `cp`, start zs3 afterward, then exercise LIST, GET, HEAD, range requests,
      and an rclone sync. No existing test covers this path, and it is the one
      the positioning depends on.

      Done: `test_foreign.py` (all checks pass, including `rclone check`).

## Milestone 2: benchmark integrity

fsync now defaults on, so the published numbers were measured under different
durability semantics than the current build.

- [ ] Re-run the Garage comparison with fsync enabled. (Blocked in this
      environment: needs Docker/Garage. The zs3-only both-modes numbers are
      published; re-run `bench/init-garage.sh` + `benchmark.py --only
      zs3,garage` where Docker exists.)
- [x] Publish both modes, labelled, rather than the faster one alone.
      (README Durability section now carries a measured both-modes table and
      labels the comparison numbers as `--fast`.)
- [x] State the durability guarantee in the README.

A defensible 4x is worth more than an indefensible 14x. Benchmark equivalence
is the first thing a reader will attack, and "no fsync" is findable in minutes.

## Milestone 3: distribution

The README's headline use case is replacing MinIO in Docker Compose, and there
is currently no image to put in the compose file.

- [x] Dockerfile and a published GHCR image (Dockerfile + multi-arch build in
      `.github/workflows/release.yml`; publishing happens on tag)
- [x] Release binaries: `x86_64-linux-musl`, `aarch64-linux-musl`, `aarch64-macos`
- [x] A working compose snippet in the README (GHCR image; full guide in
      `docs/replace-minio.md`)
- [x] Homebrew tap (formula and tap instructions in `packaging/homebrew/zs3.rb`;
      creating the `homebrew-zs3` tap repo and submitting the formula is an
      ops step outside this repo)

## Milestone 4: remaining API gaps

- [x] Checksum trailers. Neither `STREAMING-UNSIGNED-PAYLOAD-TRAILER` nor
      `x-amz-trailer` is handled. Recent botocore sends CRC32 by default on
      PUT; test against a current boto3 before assuming this is theoretical.

      Done: `decodeAwsChunkedFull` decodes all `STREAMING-*` forms and lifts
      trailers into the header map; payload checksums are verified and stored.
      `test_new.py` covers the trailer form and a current-botocore default
      CRC32 PUT (boto3 1.42 verified).

## Milestone 5: cloneable artifact history

The differentiated feature, and the reason to relaunch. See `vision.md`.

- [x] Snapshot manifest format mapping bucket/key to BLAKE3 digest
      (`docs/snapshots.md`)
- [x] `zs3 clone` over the existing CAS (warm re-clones transfer ~nothing;
      verified in `test_new.py`)
- [x] Decide the live-mesh question — decided: frozen. The mesh stays in the
      binary but receives no new work; snapshot/clone over the CAS is the
      supported way to move data between machines. Documented in `vision.md`
      and the README.

On that last point: the DHT, gossip, quorum reads, and background replication
put zs3 in the correctness weight class of a distributed object store, which is
the opposite of the "irreducibly simple" pitch. Content addressing plus an
offline `clone` command does not, because it runs as a CLI operation over
immutable digests with the filesystem still authoritative. Keeping the CAS and
freezing the live mesh preserves the interesting half.

## Milestone 6: relaunch

The previous Show HN (January 2026) led with line count, binary size, and
dependency count. Those are evidence, not a claim, and the thread drew 42 points
and one comment. That comment was the most useful thing in it: a reader who
wanted to expose a ZFS array over S3 and had settled on Garage. It describes the
wedge above.

- [ ] Submit as "turn any directory into an S3 server," not "S3 server in Zig"
      (ops action at submission time)
- [x] Prepare answers on durability, comparison to Garage and `rclone serve s3`,
      SigV4 correctness, and single-file maintainability (`docs/launch.md`)
- [ ] Stay in the thread for the first two hours

## Out of scope

Bucket policies, IAM, KMS, storage classes, notifications. Versioning,
lifecycle expiration, ACLs, tagging and SSE landed in 0.3.0 because each
one is a few hundred lines over plain files; the ones above are not. The
"what it doesn't do" section of the README is an asset. Chasing parity
trades away the only differentiated property.
