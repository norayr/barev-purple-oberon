"""Exercise Pidgin's local-insertion/Add Buddy callback order on loopback fixtures."""
import base64
import ipaddress


def encoded(text):
    return base64.b64encode(text.encode()).decode()


def add(host, name, group="Buddies", alias="Saved alias", port="default"):
    before = len(host.events)
    host.command("buddy-add " + " ".join(map(encoded, (name, group, alias))) + " " + str(port))
    count = int(host.wait("BUDDY-ADDED ").split()[1])
    notices = [base64.b64decode(event.split()[2]).decode()
               for event in host.events[before:] if event.startswith("NOTICE ")]
    return count, notices


def lookup(host, name):
    host.command("buddy-lookup " + encoded(name))
    parts = host.wait("BUDDY-LOOKUP ").split()
    return parts[1] == "1", base64.b64decode(parts[2]).decode() if len(parts) > 2 else ""


def run(Host, check):
    numeric = "lmd@201:5b1e:5e06:7daa:d39:e62c:356e:e5a6"
    label = base64.b32encode(ipaddress.IPv6Address(numeric.split("@")[1]).packed).decode().lower().rstrip("=")
    alternate = "lmd@" + label + ".barev.v6.alt"
    expanded = "lmd@0201:5B1E:5E06:7DAA:0D39:E62C:356E:E5A6"
    with Host() as host:
        for name in (numeric, numeric, numeric, expanded, alternate):
            count, notices = add(host, name)
            check(count == 2 and not notices, "the full IPv6 identity is accepted without warnings or duplicate nodes")
            check(lookup(host, name) == (True, "Saved alias"), "equivalent Add Buddy spellings preserve the existing contact and alias")
        host.command("disconnect"); host.wait("DISCONNECTED")
        host.command("reconnect"); host.wait("READY ")
        check(lookup(host, alternate) == (True, "Saved alias"), "the accepted IPv6 contact and alias survive reconnect")
        check(add(host, expanded) == (2, []), "re-adding after reconnect is idempotent")

    with Host() as host:
        for name in ("bad@not-an-ip", "lmd @201:5b1e:5e06:7daa:d39:e62c:356e:e5a6",
                     "lmd@" + numeric, "lmd@" + numeric + numeric,
                     numeric + " ", "lmd@200::2/resource", "lmd@::1"):
            for repeat in range(2):
                count, notices = add(host, name)
                check(count == 1, "a malformed addition is rolled back instead of leaving a visible rejected buddy")
                check(len(notices) == 1 and "Contact not added" in notices[0] and "username" in notices[0],
                      "malformed identities get one specific username error")
                check(not lookup(host, name)[0], "a rejected contact is absent from the lookup cache")
        for name in ("alice@200::1", "alice@0200:0:0:0:0:0:0:1", "alice@ai-e.barev.v6.alt"):
            count, notices = add(host, name)
            check(count == 1 and len(notices) == 1 and "your own Barev address" in notices[0],
                  "self-addition is rolled back and explained without calling the valid username malformed")
        for port in (-1, 65536, 70000):
            count, notices = add(host, numeric, port=port)
            check(count == 1 and len(notices) == 1 and "port must be between 1 and 65535" in notices[0],
                  "invalid contact ports are rejected with a port-specific error and no leftover node")
            check(not lookup(host, numeric)[0], "failed port setup leaves no contact in the lookup cache")
        host.command("peer-port 70000"); host.wait("PEER-PORT-SET")
        count, notices = add(host, numeric)
        check(count == 1 and len(notices) == 1 and "default peer port" in notices[0],
              "a bad default port is identified separately from the valid username")
        host.command("peer-port 9"); host.wait("PEER-PORT-SET")
        check(add(host, numeric) == (2, []), "correcting a failed port allows a clean retry")

    with Host() as host:
        for index in range(127):
            count, notices = add(host, f"contact{index}@200::3")
            check(count == index+2 and not notices, "contacts can be added up to the supported account limit")
        for repeat in range(2):
            count, notices = add(host, numeric)
            check(count == 128 and len(notices) == 1 and "maximum of 128" in notices[0],
                  "a full contact table rejects the addition without leaving extra nodes or blaming the username")
        check(add(host, "contact0@200::3") == (128, []), "re-adding an existing contact succeeds even at the limit")

    with Host() as host:
        host.command("reentrant-notice"); host.wait("ARMED")
        count, notices = add(host, "bad@not-an-ip")
        check(count == 1 and len(notices) == 1, "error reporting tolerates the UI disconnecting the account")
