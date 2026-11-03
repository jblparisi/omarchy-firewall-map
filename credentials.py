#!/usr/bin/env python3
"""Atomically store GUI credentials; the password is read only from stdin."""

import json
import os
from pathlib import Path
import sys
import tempfile


def save_credentials(path, text):
    if len(text) > 65536:
        raise ValueError("Credentials are too large")
    document = json.loads(text)
    if not isinstance(document, dict) or any(
        not isinstance(document.get(key), str) or not document[key]
        for key in ("username", "password")
    ):
        raise ValueError("A username and password are required")
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".firewall-map-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump({key: document[key] for key in ("username", "password")}, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Expected a destination path")
        save_credentials(sys.argv[1], sys.stdin.readline(65537))
    except (OSError, ValueError, TypeError):
        print("Could not save credentials; check the fields and directory permissions.", file=sys.stderr)
        sys.exit(1)
