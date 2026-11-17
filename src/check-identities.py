#!/usr/bin/env python3
"""Private identity storage, fingerprint and optional cross-implementation tests.

Pass one or more identity-test executables. All files and connections stay local.
"""
import concurrent.futures
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
RECORD = b"BAREVID1" + SEED + PUBLIC


def account_name(name):
    return hashlib.sha256(b"Barev account v1\n" + name.encode()).hexdigest() + ".identity"


def snapshot(root):
    result = {}
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            value = os.readlink(path)
        elif stat.S_ISREG(mode):
            try:
                value = path.read_bytes()
            except PermissionError:
                value = "unreadable"
        else:
            value = None
        result[str(path.relative_to(root))] = (mode, value)
    return result


def main():
    tools = [str(Path(p).resolve()) for p in sys.argv[1:]]
    if not tools:
        raise SystemExit("usage: check-identities.py IDENTITY-TEST [IDENTITY-TEST ...]")
    checks = 0

    def run(tool, root, account="alice", expected="", status=0):
        nonlocal checks
        result = subprocess.run([tool, str(root), account, expected], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        if result.returncode:
            raise AssertionError((tool, result.returncode, result.stdout, result.stderr))
        lines = result.stdout.splitlines()
        assert lines and int(lines[0]) == status, (tool, root, account, expected, status, lines, result.stderr)
        if status == 0:
            assert len(lines) == 3 and len(lines[1]) == 64, lines
            public = bytes.fromhex(lines[1])
            assert lines[2] == "SHA256:" + hashlib.sha256(public).hexdigest(), lines
        else:
            assert len(lines) == 1, lines
        checks += 1
        return lines

    with tempfile.TemporaryDirectory(prefix="barev-identities-") as directory:
        base = Path(directory)
        for index, tool in enumerate(tools):
            root = base / f"created-{index}"
            first = run(tool, root)
            public = first[1]
            key = root / "barev/identities" / (public + ".key")
            link = root / "barev/accounts" / account_name("alice")
            record = key.read_bytes()
            assert len(record) == 72 and record[:8] == b"BAREVID1" and record[40:].hex() == public
            assert link.read_bytes() == b"BAREVAC1" + bytes.fromhex(public)
            for path in (root / "barev", root / "barev/identities", root / "barev/accounts"):
                assert stat.S_IMODE(path.stat().st_mode) == 0o700
            for path in (key, link):
                assert stat.S_IMODE(path.stat().st_mode) == 0o600 and path.stat().st_nlink == 1
            for other in tools:
                assert run(other, root) == first
                assert run(other, str(root)+"/", expected=public) == first
            before = snapshot(root)
            run(tool, root, expected="x", status=4)
            run(tool, root, expected=public+"0", status=4)
            run(tool, root, expected="G"*64, status=4)
            run(tool, root, account="", status=3)
            run(tool, root, account="a"*257, status=3)
            assert before == snapshot(root)
            assert run(tool, root, account="renamed", expected=public) == first
            assert len(list((root / "barev/identities").iterdir())) == 1
            second = run(tool, root, account="bob")
            assert second[1] != public
            before = snapshot(root)
            run(tool, root, expected=second[1], status=6)
            assert before == snapshot(root)
            assert run(tool, root, account="../alice@200::1/", expected=public) == first
            assert run(tool, root, account="Ալիս", expected=public) == first

        template = base / "template"
        keys, links = template / "barev/identities", template / "barev/accounts"
        keys.mkdir(parents=True, mode=0o700); links.mkdir(mode=0o700)
        (template / "barev").chmod(0o700)
        key = keys / (PUBLIC.hex()+".key"); key.write_bytes(RECORD); key.chmod(0o600)
        link = links / account_name("alice"); link.write_bytes(b"BAREVAC1"+PUBLIC); link.chmod(0o600)

        mutations = []
        def key_bytes(data):
            return lambda r: (r/"barev/identities"/(PUBLIC.hex()+".key")).write_bytes(data)
        def link_bytes(data):
            return lambda r: (r/"barev/accounts"/account_name("alice")).write_bytes(data)
        mutations += [("key-header", key_bytes(b"X"+RECORD[1:]), 2),
                      ("key-seed", key_bytes(RECORD[:8]+bytes([SEED[0]^1])+RECORD[9:]), 2),
                      ("key-public", key_bytes(RECORD[:-1]+bytes([PUBLIC[-1]^1])), 2),
                      ("key-empty", key_bytes(b""), 1),
                      ("key-short", key_bytes(RECORD[:-1]), 1),
                      ("key-long", key_bytes(RECORD+b"x"), 1),
                      ("link-header", link_bytes(b"XAREVAC1"+PUBLIC), 2),
                      ("link-short", link_bytes(b"BAREVAC1"+PUBLIC[:-1]), 1)]
        key_path = Path("barev/identities")/(PUBLIC.hex()+".key")
        link_path = Path("barev/accounts")/account_name("alice")
        for relative in (key_path, link_path):
            for mode in (0o644, 0o400, 0o666, 0):
                mutations.append((str(relative)+str(mode), lambda r, p=relative, m=mode: (r/p).chmod(m), 1))
            def missing(root, p=relative):
                (root/p).unlink()
            # A missing account link can be recovered from the configured key.
            mutations.append((str(relative)+"missing", missing, 1 if relative == key_path else 0))
            def symlink(root, p=relative):
                (root/p).unlink(); (root/p).symlink_to(base/"outside")
            mutations.append((str(relative)+"symlink", symlink, 1))
            def hardlink(root, p=relative):
                os.link(root/p, root/"other-link")
            mutations.append((str(relative)+"hardlink", hardlink, 1))
            def fifo(root, p=relative):
                (root/p).unlink(); os.mkfifo(root/p, 0o600)
            mutations.append((str(relative)+"fifo", fifo, 1))
            def folder(root, p=relative):
                (root/p).unlink(); (root/p).mkdir(mode=0o600)
            mutations.append((str(relative)+"directory", folder, 1))
        for relative in (Path("barev"), Path("barev/identities"), Path("barev/accounts")):
            mutations.append((str(relative)+"permissions", lambda r, p=relative: (r/p).chmod(0o755), 1))
            def linked_directory(root, p=relative):
                (root/p).rename(root/(p.name+"-moved")); (root/p).symlink_to(root/(p.name+"-moved"))
            mutations.append((str(relative)+"symlink", linked_directory, 1))
        mutations.append(("profile-permissions", lambda r: r.chmod(0o770), 1))
        (base/"outside").write_bytes(b"outside must not change")
        for index, (label, mutate, status) in enumerate(mutations):
            for number, tool in enumerate(tools):
                root = base/f"bad-{index}-{number}"
                shutil.copytree(template, root)
                mutate(root)
                before = snapshot(root)
                run(tool, root, expected=PUBLIC.hex(), status=status)
                if status:
                    assert snapshot(root) == before, label
                assert (base/"outside").read_bytes() == b"outside must not change"
                # Restore search permissions for cleanup on unprivileged hosts.
                for path in (root, root/"barev", root/"barev/identities", root/"barev/accounts"):
                    if path.is_dir() and not path.is_symlink():
                        path.chmod(0o700)

        for tool in tools:
            empty_profile = base/("missing-configured-"+str(checks))
            run(tool, empty_profile, expected=PUBLIC.hex(), status=1)
            assert not list((empty_profile/"barev/identities").glob("*.key"))
            root = base/("known-"+str(checks))
            shutil.copytree(template, root)
            result = run(tool, root, expected=PUBLIC.hex())
            assert result[1] == PUBLIC.hex()
            renamed = run(tool, root, account="renamed", expected=PUBLIC.hex())
            assert renamed == result
            assert (root/"barev/accounts"/account_name("renamed")).is_file()
            lock = os.open(root/"barev", os.O_RDONLY)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                run(tool, root, expected=PUBLIC.hex(), status=1)
            finally:
                os.close(lock)
            symlink = base/("profile-link-"+str(checks)); symlink.symlink_to(root)
            run(tool, symlink, expected=PUBLIC.hex(), status=1)

        race_root = base/"concurrent"
        def attempt(index):
            tool = tools[index % len(tools)]
            result = subprocess.run([tool, str(race_root), "alice", ""], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
            assert result.returncode == 0, result.stderr
            return result.stdout.splitlines()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(attempt, range(16)))
        successes = [r for r in results if r[0] == "0"]
        assert successes and all(r == successes[0] for r in successes)
        assert all(r[0] in ("0", "1") for r in results)
        for tool in tools:
            assert run(tool, race_root) == successes[0]
        assert len(list((race_root/"barev/identities").iterdir())) == 1
    print(f"Identity storage: {checks} scenarios passed across {len(tools)} implementation(s)")


if __name__ == "__main__":
    main()
