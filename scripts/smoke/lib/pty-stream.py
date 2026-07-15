#!/usr/bin/env python3
"""Run a command on a PTY and copy its stdout immediately.

White Noise's long-lived notification CLI buffers stdout when redirected to a
regular file. A PTY keeps its normal line-flush behavior; this tiny adapter
copies each PTY read to stdout without adding terminal recorder headers.
"""

from __future__ import annotations

import errno
import os
import pty
import signal
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: pty-stream.py COMMAND [ARG ...]", file=sys.stderr)
        return 2

    master, slave = pty.openpty()
    child = subprocess.Popen(  # noqa: S603 - caller intentionally selects the binary
        sys.argv[1:],
        stdin=subprocess.DEVNULL,
        stdout=slave,
        stderr=None,
        close_fds=True,
    )
    os.close(slave)

    def stop(_signum: int, _frame: object) -> None:
        if child.poll() is None:
            child.terminate()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    try:
        while True:
            try:
                chunk = os.read(master, 64 * 1024)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            # PTYs use CRLF. JSON accepts LF, and removing CR keeps the evidence
            # file directly consumable by jq while preserving all JSON bytes.
            sys.stdout.buffer.write(chunk.replace(b"\r", b""))
            sys.stdout.buffer.flush()
    finally:
        os.close(master)
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()

    return child.returncode or 0


if __name__ == "__main__":
    raise SystemExit(main())
