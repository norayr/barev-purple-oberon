#!/usr/bin/env python3
"""Validate durable publishing operations in isolated profile processes."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

tool = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="publishing-", dir=tool.parent) as directory:
    base = Path(directory)
    profile = base / "profile"
    env = dict(os.environ, HOME=str(base), XDG_CONFIG_HOME=str(base),
               XDG_DATA_HOME=str(base), XDG_CACHE_HOME=str(base))
    for action in ("new", "verify", "invalid"):
        if action == "invalid":
            checkpoint, = (profile / "barev").glob("posts-*.state")
            checkpoint.write_bytes(b"corrupt checkpoint")
        result = subprocess.run([str(tool), str(profile), action], env=env,
                                text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, (result.stdout, result.stderr)
        print(result.stdout, end="")
