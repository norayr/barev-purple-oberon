# Barev addresses

Barev contacts have a nickname and a Yggdrasil IPv6 address. You can enter either
of these forms in Pidgin's **Add Buddy** dialog:

```text
nick@200::1
nick@ai-e.barev.v6.alt
```

Both identify the same contact. Existing IPv6 contacts continue to work, and
libpurple uses the decoded numeric identity when matching contacts. Nickname
case is significant. A Pidgin alias is a separate local display label; your
chosen aliases are preserved.

Re-adding the same identity to the same group reuses the existing contact,
including when its IPv6 address is entered with a different valid spelling or
as an encoded hostname. While the account is connected, a rejected addition
is removed from the local buddy list. Errors distinguish an invalid username,
your own address, an invalid contact port, the 128-contact account limit and
protocol-runtime failures.

## Viewing and sharing addresses

- Open a contact's **Get Info** window to see its **IPv6** and full **Barev
  address**. These are computed locally, including when the contact is offline.
- Connect your account, then choose **Accounts → your Barev account → My Barev
  address**. Copy the full `nick@<encoded>.barev.v6.alt` value and share it.

The account action uses the IPv6 address selected for the current account.
If you use a nondefault listening port, also tell the recipient that port;
the encoded address contains only the IPv6 address. The default chat port
remains 1337.

Encoding and decoding run inside the plugin without DNS queries or additional
software. Peer streams continue using numeric IPv6 identities, so contacts using
older plugins remain compatible.

## Encoding

The address label follows the [v6.alt scheme](https://modules.prosody.im/mod_s2s_v6mesh.html):
encode the 16 IPv6 bytes as 26 lowercase, unpadded RFC 4648 base32 characters,
then replace the first longest interior run of at least two `a` characters with
`-`. Append `.barev.v6.alt`.

Input accepts uppercase hostnames, an optional final dot, uncompressed labels,
and alternate valid zero-run compression. Output always uses the canonical
lowercase spelling. Multiple hyphens, invalid characters, nonzero base32 padding
bits, and addresses outside Yggdrasil's `200::/7` range are rejected for contacts.

The codec and identity handling are implemented in checked `src/BarevAddress.Mod`;
the native adapter supplies the libpurple information windows and account menu.
Run `make protocol-address-test` for codec, contact lookup, alias, account-action,
and numeric-wire compatibility checks in isolated local fixtures.
