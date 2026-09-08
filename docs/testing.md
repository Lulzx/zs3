# Testing

The boto3 suites need `pip install boto3`. The rest are stdlib only.

```bash
zig build test                  # 60 unit tests
python3 test_client.py          # 28 integration tests (stdlib)
python3 test_comprehensive.py   # 87 boto3 tests, standalone
python3 test_new.py             # ETags, checksums, trailers, presigned URLs, snapshot/clone
python3 test_foreign.py         # foreign tree: LIST/GET/HEAD/range + rclone check
python3 test_features.py        # 100 checks: versioning, lifecycle, ACLs, tagging, SSE-S3/SSE-C
python3 test_bootstrap.py       # two-node bootstrap discovery
python3 test_replication.py     # four-node replication suite (stdlib)
```

The server-backed suites expect a server on port 9000. Start one first:

```bash
zig build -Doptimize=ReleaseSmall
rm -rf /tmp/zs3-test && mkdir -p /tmp/zs3-test
./zig-out/bin/zs3 --data-dir=/tmp/zs3-test --port=9000 --lifecycle-interval-s=2 &
```

`test_features.py` waits five seconds for lifecycle passes, so the server
needs `--lifecycle-interval-s=2` (the default is an hour).

`test_new.py` also runs the `zs3` binary directly for snapshot and clone. It
looks for `zig-out/bin/zs3` in the repo, or `$ZS3_BIN` if set.

For the distributed suite, run the boto3 tests against a node started with
`--distributed` (92 tests pass there).

Check compatibility against aws-cli, boto3, and rclone:

```bash
./scripts/verify-clients.sh
```

CI runs the unit tests, a musl cross-build matrix, the integration suites, and
the replication suite on every push. See `.github/workflows/ci.yml`.
