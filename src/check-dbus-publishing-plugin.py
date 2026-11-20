#!/usr/bin/env python3
"""Exercise the native publishing backend through a disposable plugin session."""
import fcntl
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

build = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="dbus-publishing-plugin-", dir=build) as directory:
    profile = Path(directory)
    env = dict(os.environ, HOME=str(profile), XDG_CONFIG_HOME=str(profile),
               XDG_DATA_HOME=str(profile), XDG_CACHE_HOME=str(profile), G_DEBUG="fatal-criticals",
               GIO_USE_VFS="local", GSETTINGS_BACKEND="memory")
    with tempfile.TemporaryFile(dir=profile) as errors:
        host = subprocess.Popen([str(build / "ProtocolHost"), str(build / "libvoc-barev-test.so"),
                                 str(profile), "9", "test", "Անի", "bob@200::2"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                env=env, bufsize=0)
        selector = selectors.DefaultSelector()
        selector.register(host.stdout, selectors.EVENT_READ)
        buffer = b""

        def wait(prefix):
            global buffer
            while True:
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if line.decode().startswith(prefix):
                        return line.decode()
                assert selector.select(30), prefix
                data = os.read(host.stdout.fileno(), 65536)
                if not data:
                    errors.seek(0)
                    raise AssertionError(errors.read().decode(errors="replace"))
                buffer += data

        def command(text, prefix):
            host.stdin.write((text + "\n").encode())
            host.stdin.flush()
            return wait(prefix)

        def client(mode):
            result = subprocess.run([str(build / "DBusPublishingClient"), identity, mode], env=env,
                                    text=True, capture_output=True, timeout=30)
            assert result.returncode == 0, (mode, result.stdout, result.stderr)
            print(result.stdout, end="")

        try:
            wait("READY ")
            subprocess.run(["gdbus", "wait", "--session", "--timeout", "10", "org.barev.Native"], check=True)
            identity = next((profile / "barev/identities").glob("*.key")).stem
            client("new")
            descriptor = os.open(profile / "barev", os.O_RDONLY | os.O_DIRECTORY)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                client("fail-write")
            finally:
                os.close(descriptor)
            client("recover")
            command("disconnect", "DISCONNECTED")
            command("reconnect", "READY ")
            client("verify")
            command("publish-pause", "PUBLISH-PAUSED")
            deferred = subprocess.Popen([str(build / "DBusPublishingClient"), identity, "deferred"],
                                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            pending = selectors.DefaultSelector()
            pending.register(deferred.stdout, selectors.EVENT_READ)
            try:
                assert pending.select(30), "deferred publication deadline"
                assert deferred.stdout.readline().strip() == "PENDING"
                command("disconnect", "DISCONNECTED")
                output, failure = deferred.communicate(timeout=15)
                assert deferred.returncode == 0, (output, failure)
                print(output, end="")
            finally:
                pending.close()
                if deferred.poll() is None:
                    deferred.kill()
                    deferred.wait(timeout=5)
            command("publish-resume", "PUBLISH-RESUMED")
            command("reconnect", "READY ")
            client("accepted")
            for failure in (None, "fail-remove", "fail-timer", "deadline"):
                command("disconnect", "DISCONNECTED")
                command("profile-hold", "PROFILE-HELD")
                if failure == "fail-timer":
                    command(failure, "ARMED")
                    command("reconnect", "ERROR ")
                else:
                    host.stdin.write(b"reconnect\n")
                    host.stdin.flush()
                    command("state", "STATE ")
                    assert command("can-unload", "UNLOAD ") == "UNLOAD 0"
                    if failure is None:
                        command("profile-release", "PROFILE-RELEASED")
                        wait("READY ")
                        client("verify")
                        continue
                    elif failure == "deadline":
                        wait("ERROR ")
                    elif failure:
                        command(failure, "ARMED")
                command("disconnect", "DISCONNECTED")
                command("profile-release", "PROFILE-RELEASED")
                command("reconnect", "READY ")
                client("verify")
            command("disconnect", "DISCONNECTED")
            checkpoint = profile / "barev" / f"posts-{identity}.state"
            checkpoint.unlink()
            command("reconnect", "READY ")
            client("missing")
            command("disconnect", "DISCONNECTED")
            deadline = time.monotonic() + 10
            while command("can-unload", "UNLOAD ") != "UNLOAD 1":
                assert time.monotonic() < deadline, "publishing did not drain"
            command("quit", "CLOSED")
            assert host.wait(timeout=10) == 0
            settings = ET.parse(profile / "accounts.xml")
            assert any(node.get("name") == "barev_publishing" and node.text == "initialized"
                       for node in settings.iter("setting")), "publishing setup marker was not persisted"
        finally:
            if host.poll() is None:
                host.kill()
                host.wait(timeout=5)
            selector.close()
            host.stdin.close()
            host.stdout.close()
print("Native D-Bus publishing lifecycle: reconnect, contention, deferred-login and disconnect checks passed")
