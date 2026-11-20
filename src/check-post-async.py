#!/usr/bin/env python3
"""Check asynchronous Oberon checkpoint validation in isolated processes."""
from pathlib import Path
import os
import struct
import subprocess
import sys
import tempfile
import zlib

tool = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="post-async-", dir=tool.parent) as directory:
    base = Path(directory)
    profile = base / "profile"
    env = dict(os.environ, HOME=str(base), XDG_CONFIG_HOME=str(base),
               XDG_DATA_HOME=str(base), XDG_CACHE_HOME=str(base))

    def run(path, action, valid=profile):
        result = subprocess.run([str(tool), str(path), action, str(valid)], env=env,
                                text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, (result.stdout, result.stderr)
        print(result.stdout, end="")

    run(profile, "new")
    run(profile, "verify")
    original, = (profile / "barev").glob("posts-*.state")
    data = original.read_bytes()
    wrong_owner = data[:16] + b"0" + data[17:-4]
    for number, image in enumerate((b"", data[:-1], b"corrupt",
                                     wrong_owner + struct.pack(">I", zlib.crc32(wrong_owner)))):
        invalid = base / ("invalid-" + str(number))
        (invalid / "barev").mkdir(parents=True, mode=0o700)
        (invalid / "barev" / original.name).write_bytes(image)
        run(invalid, "invalid")
