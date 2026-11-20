#!/usr/bin/env python3
"""Exercise checkpoint restarts and failure handling in disposable profiles."""
import fcntl
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import zlib

tool = str(Path(sys.argv[1]).resolve())
build = Path(tool).parent
owner = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


def run(profile, action="inspect", status=0, counts=None, key=owner):
    env = dict(os.environ, HOME=str(profile), XDG_CONFIG_HOME=str(profile),
               XDG_CACHE_HOME=str(profile), XDG_DATA_HOME=str(profile))
    result = subprocess.run([tool, str(profile), action, key], env=env, text=True,
                            capture_output=True, timeout=30)
    check(result.returncode == 0)
    lines = result.stdout.splitlines()
    assert lines and lines[0] == str(status), (action, result.stdout, result.stderr)
    check(lines[0] == str(status))
    if counts is not None:
        check(lines[1:] == [" ".join(map(str, counts))])
    else:
        check(len(lines) == 1)


def path(profile, key=owner):
    return profile / "barev" / ("posts-" + key + ".state")


def seal(data):
    return data + struct.pack(">I", zlib.crc32(data))


def parse(data):
    check(zlib.crc32(data[:-4]) == struct.unpack(">I", data[-4:])[0])
    pos = 0

    def word():
        nonlocal pos
        value = struct.unpack_from(">I", data, pos)[0]
        pos += 4
        return value

    def text():
        nonlocal pos
        length = word()
        value = data[pos:pos + length].decode()
        pos += length
        return value

    check(text() == "BAREVPS1")
    check(text() == owner)
    check([word(), word(), word()] == [8, 32, 65536])
    nodes, slots = word(), word()
    destinations = []
    for _ in range(nodes):
        name, title, model, count = text(), text(), word(), word()
        destinations.append((name, title, model, [text() for _ in range(count)]))
    check(destinations == [("public", "Public", 1, []),
                           ("selected", "Selected", 3, ["reader@200::2"])])
    posts = []
    for _ in range(slots):
        node, state, item, atom = word(), word(), text(), text()
        body = [text() for _ in range(6)] if state else None
        posts.append((node, state, item, atom, body))
    check(pos == len(data) - 4)
    check(posts[0][4][-1] == "Բարեւ <world> & 😀")
    check(posts[1][0] == 1 and posts[1][4][-1] == "Private text")
    check(posts[2] == (0, 0, "post-3", "urn:post:3", None))
    check(posts[3][4][-2] == "urn:post:1")


with tempfile.TemporaryDirectory(prefix="post-files-", dir=build) as directory:
    base = Path(directory)
    profile = base / "main"
    run(profile, status=1)
    check(not path(profile).exists())
    check(stat.S_IMODE((profile / "barev").stat().st_mode) == 0o700)
    run(profile, "new", counts=(3, 4))
    run(profile, counts=(3, 4))
    original = path(profile).read_bytes()
    parse(original)
    inode = path(profile).stat().st_ino
    run(profile, "retry", counts=(3, 4))
    check(path(profile).read_bytes() == original and path(profile).stat().st_ino == inode)
    run(profile, "bad-load", status=2, counts=(3, 4))
    run(profile, "closed", status=2, counts=(3, 4))
    run(profile, "forget", status=4, counts=(0, 0))
    check(path(profile).read_bytes() == original)
    run(profile, key="0" * 64, status=1)
    check(not path(profile, "0" * 64).exists())
    run(profile, key="bad", status=2)
    run(profile, key="a" * 65, status=2)
    run(profile, key="A" * 64, status=2)
    run(Path("relative-profile"), status=2)
    run(base / ("a" * 3801), status=2)

    descriptor = os.open(profile / "barev", os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run(profile, status=3)
    finally:
        os.close(descriptor)
    check(path(profile).read_bytes() == original)

    for malformed in (b"", original[:-1], original + b"x",
                      original[:40] + bytes([original[40] ^ 1]) + original[41:],
                      seal(original[:-4] + b"extra"),
                      seal(original[:11] + b"2" + original[12:-4]),
                      seal(original[:16] + b"0" + original[17:-4])):
        path(profile).write_bytes(malformed)
        run(profile, status=2)
        run(profile, "new", status=2)
        check(path(profile).read_bytes() == malformed)
    path(profile).write_bytes(original)
    with path(profile).open("r+b") as stream:
        stream.truncate(6 * 1024 * 1024 + 1)
    run(profile, status=2)
    path(profile).write_bytes(original)

    path(profile).unlink()
    outside = base / "outside"
    outside.write_bytes(original)
    path(profile).symlink_to(outside)
    run(profile, status=3)
    check(outside.read_bytes() == original)
    path(profile).unlink()
    path(profile).mkdir()
    run(profile, status=3)
    path(profile).rmdir()
    os.mkfifo(path(profile))
    run(profile, status=3)
    path(profile).unlink()
    path(profile).write_bytes(original)
    (profile / "barev").chmod(0o755)
    run(profile, status=3)
    (profile / "barev").chmod(0o700)
    run(profile, counts=(3, 4))
    real = profile / "private-barev"
    (profile / "barev").rename(real)
    (profile / "barev").symlink_to(real)
    run(profile, status=3)
    (profile / "barev").unlink()
    real.rename(profile / "barev")
    check(path(profile).read_bytes() == original)
    check(not list((profile / "barev").glob("*.tmp.*")))

    run(profile, "two", status=4, counts=(4, 5))
    run(profile, "winner", counts=(4, 5))
    run(profile, "delete", status=4, counts=(4, 5))
    check(not path(profile).exists())
    run(profile, status=1)

print(f"Post checkpoint files: {checks} checks passed")
