#!/usr/bin/env python3
"""Independently inspect the generated standalone Atom entry."""
import subprocess
import sys
import xml.etree.ElementTree as ET

data = subprocess.check_output([sys.argv[1], "emit"], timeout=15)
entry = ET.fromstring(data)
atom = "{http://www.w3.org/2005/Atom}"
thread = "{http://purl.org/syndication/thread/1.0}"
assert entry.tag == atom + "entry"
assert len(entry.findall(atom + "content")) == 1
assert entry.find(atom + "content").attrib == {"type": "text"}
assert entry.findtext(atom + "content") == "Text <script> & literal entities: &amp;\r\n\tx"
assert entry.findtext(atom + "title") == "Բարեւ <world> & 😀"
assert entry.findtext(atom + "author/" + atom + "name") == "Անի@200::1"
assert entry.findtext(atom + "id") == "urn:uuid:00000000-0000-4000-8000-000000000001"
assert entry.findtext(atom + "published") == "2026-11-20T00:00:00Z"
assert entry.findtext(atom + "updated") == "2026-11-20T00:00:01Z"
assert entry.find(thread + "in-reply-to").attrib == {
    "ref": "https://example.org/post/parent?x=1&y=2#context"
}
assert "d75a9801" not in data.decode()
print("Atom XML: 11 independent parser checks passed")
