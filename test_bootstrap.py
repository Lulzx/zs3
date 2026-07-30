#!/usr/bin/env python3
"""Two-node regression test for --bootstrap peer discovery."""

import json
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def get_json(url, timeout=5):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                return json.load(response)
        except Exception as error:
            last_error = error
            time.sleep(0.1)
    raise AssertionError(f"{url} did not become ready: {last_error}")


def stop(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zs3").resolve()
    if not executable.is_file():
        raise SystemExit(f"zs3 executable not found: {executable}")

    port_a = unused_port()
    port_b = unused_port()

    with tempfile.TemporaryDirectory(prefix="zs3-bootstrap-test-") as temp_dir:
        root = Path(temp_dir)
        log_a = (root / "node-a.log").open("w+")
        log_b = (root / "node-b.log").open("w+")
        node_a = subprocess.Popen(
            [
                executable,
                "--distributed",
                f"--port={port_a}",
                f"--data-dir={root / 'node-a'}",
            ],
            stdout=log_a,
            stderr=subprocess.STDOUT,
        )
        node_b = None
        try:
            ping_a = get_json(f"http://127.0.0.1:{port_a}/_zs3/ping")
            node_b = subprocess.Popen(
                [
                    executable,
                    "--distributed",
                    f"--port={port_b}",
                    f"--bootstrap=localhost:{port_a}",
                    f"--data-dir={root / 'node-b'}",
                ],
                stdout=log_b,
                stderr=subprocess.STDOUT,
            )

            peers = get_json(f"http://127.0.0.1:{port_b}/_zs3/peers")
            assert any(
                peer["id"] == ping_a["id"] and peer["port"] == port_a
                for peer in peers
            ), f"node B did not learn node A: {peers}"

            ping_b = get_json(f"http://127.0.0.1:{port_b}/_zs3/ping")
            peers_a = get_json(f"http://127.0.0.1:{port_a}/_zs3/peers")
            assert any(
                peer["id"] == ping_b["id"] and peer["port"] == port_b
                for peer in peers_a
            ), f"node A did not learn node B: {peers_a}"
        except Exception:
            log_a.seek(0)
            log_b.seek(0)
            sys.stderr.write(f"\nnode A log:\n{log_a.read()}")
            sys.stderr.write(f"\nnode B log:\n{log_b.read()}")
            raise
        finally:
            if node_b is not None:
                stop(node_b)
            stop(node_a)
            log_a.close()
            log_b.close()

    print("bootstrap peer discovery passed")


if __name__ == "__main__":
    main()
