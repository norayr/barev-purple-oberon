#!/usr/bin/env python3
"""Validate asynchronous account commits with disposable profile processes."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

tool = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="publish-async-", dir=tool.parent) as directory:
    base = Path(directory)
    profile = base / "profile"
    env = dict(os.environ, HOME=str(base), XDG_CONFIG_HOME=str(base),
               XDG_DATA_HOME=str(base), XDG_CACHE_HOME=str(base))
    for action in ("new", "verify", "lost", "invalid"):
        if action == "invalid":
            owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
            (profile / "barev" / f"posts-{owner}.state").write_bytes(b"corrupt checkpoint")
        result = subprocess.run([str(tool), str(profile), action], env=env,
                                text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, (result.stdout, result.stderr)
        print(result.stdout, end="")
