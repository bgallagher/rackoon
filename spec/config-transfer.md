# Config transfer format (`rackoon-config`, version 1)

One document moves a Rackoon setup between devices and serves as a backup. Every platform reads and writes the same
format; `config-transfer.schema.json` is its shape, `config-transfer.json` maps each setting to where each app keeps it,
and `scenarios/config-codec.json`, `scenarios/config-merge.json` and `fixtures/config/` are the cases every core must
pass. The design and its reasons are in `docs/config-transfer.md`.

## The document

UTF-8 JSON. Readers ignore fields they do not know, so later additions inside version 1 never break older apps. A
document whose `version` is greater than 1 is refused ("made by a newer Rackoon"), never half read.

```json
{
  "format": "rackoon-config",
  "version": 1,
  "exportedAt": "2026-11-27T12:00:00Z",
  "source": {"platform": "mac", "app": "0.1.0"},
  "servers": [{"id": "…", "name": "homelab", "host": "homelab", "user": "andy", "port": 22,
               "sshConfigAlias": "homelab", "identityFile": "~/.ssh/id_ed25519",
               "resolved": {"host": "100.64.0.10", "user": "andy", "port": 22}}],
  "hostKeys": [{"host": "100.64.0.10", "port": 22, "type": "ssh-ed25519", "key": "AAAAC3NzaC1lZDI1NTE5AAAA…"}],
  "signIn": {"<server id>": {"method": "key", "keyName": "id_ed25519"}},
  "preferences": {"theme": "automatic", "readOnly": true, "highlightOutput": true},
  "serverSettings": {"<server id>": {"icons": {"immich": "immich"}, "services": {"nginx": false},
                                     "vulnerabilityLookup": true, "mutedAlerts": ["disk|/srv"]},
                     "*": {"services": {"tailscaled": true}}},
  "customIcons": {"<sha256 hex>": "<base64 PNG>"},
  "secrets": {"<server id>": {"password": "…"}}
}
```

- `servers`: in the exporter's saved order. An empty `user` reads as no user. `host`, `user` and `port` are what that device connects with. `sshConfigAlias`
  and `identityFile` only mean something on a Mac. `resolved` is what a Mac's `ssh -G` said the alias connects to, so a
  device without that ~/.ssh/config still gets a real address.
- `hostKeys`: trusted keys by the address they are pinned for (`host` lower-case, `port`), `type` as ssh names it, `key`
  base64 of the wire-format key (as in known_hosts). A host may have several (a Mac's known_hosts often does).
- `signIn`: per server, `method` is `tailscale` (SSH `none`), `key`, `password` or `system` (a Mac's own ssh setup:
  agent, ~/.ssh/config, default keys). `keyName` is for display. Never a secret.
- `preferences`: catalog ids from `config-transfer.json` whose `part` is `preferences`, each with its catalog `type`. A
  value of the wrong type, or an unknown id, is dropped when reading. An id the exporter does not have is simply absent.
- `serverSettings`: per server id. `icons` maps an icon-choice key with the server id taken off the front
  (`<stack id>[|<service>]` or `service:<id>`) to an icon id (`""` = the letter); `services` maps a service id to shown
  or hidden; `vulnerabilityLookup` is the per-server opt-in; `mutedAlerts` are alert ids with the server id taken off
  (`<source>|<key>`). The entry `"*"` holds rules for every server and only uses `services`.
- `customIcons`: images the user added, keyed by the lower-case hex their `custom:` icon id names (16 to 64
  characters; the apps use the first 32 of the PNG's SHA-256). Files only, never a QR.
- `secrets`: per server `password`, or `privateKey` (OpenSSH or PEM text) with an optional `passphrase`, and `keyName`.
  **Only inside an encrypted file.** A reader drops `secrets` from a plain document and from a QR transfer, and drops
  `customIcons` from a QR transfer.

Device-local things are never in a document: saved sudo passwords, cached snapshots, favicon and icon caches, the
vulnerability answer cache, Security readings, alert history and "seen" marks, the selected server, the Dashboard page,
the start screen, demo mode, the supporter licence, the web app's own sign-in, and push subscriptions.
`config-transfer.json` lists each with its reason.

## Plain file

The document itself, pretty-printed, extension `.rackoon`. It never carries `secrets`.

## Encrypted file

```json
{"format": "rackoon-config-encrypted", "version": 1,
 "kdf": {"name": "PBKDF2-SHA256", "iterations": 600000, "salt": "<base64, 16 bytes>"},
 "cipher": "AES-256-GCM", "compression": "deflate-raw",
 "nonce": "<base64, 12 bytes>", "ciphertext": "<base64: encrypted bytes followed by the 16-byte tag>"}
```

- Key: PBKDF2-HMAC-SHA256 over the passphrase (Unicode NFC, then UTF-8), 32 bytes. Writers use 600,000 iterations;
  readers accept 100,000 to 5,000,000 and call anything else damaged (a huge count would hang the device).
- The passphrase must be at least 10 characters (Unicode code points after NFC). It is never stored.
- Plaintext: the document's UTF-8 JSON, compressed with raw DEFLATE (RFC 1951, no zlib or gzip header). A reader stops
  inflating past 16 MiB.
- Additional authenticated data: the ASCII text `rackoon-config-encrypted/1`.
- A failed tag check means a wrong passphrase or a changed file; the reader says "wrong passphrase, or the file was
  changed" and nothing is imported.
- Base64 is the standard alphabet with padding.

## QR transfer

The document, without `secrets` and `customIcons`, compressed and encrypted, then split into parts shown one after
another.

- **Unlock code**: 10 symbols of Crockford base32 (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`), 50 random bits, shown as
  `XXXXX-XXXXX`. When typed it is upper-cased, spaces and hyphens are removed, `O` reads as `0` and `I` and `L` as `1`;
  anything else that is not 10 alphabet symbols is refused before any work. The key is PBKDF2-HMAC-SHA256 over the 10
  normalised symbols (ASCII), the payload's salt, 600,000 iterations, 32 bytes.
- **Payload**: the byte `0x01`, a 16-byte salt, a 12-byte nonce, then AES-256-GCM of the raw-DEFLATE JSON (tag last)
  with the ASCII text `rackoon-config-qr/1` as additional authenticated data.
- **Parts**: with at most `maxPartBytes` payload bytes per part (450 by default), `total = ceil(length / maxPartBytes)`,
  `size = ceil(length / total)`, and part `n` (from 1) holds bytes `(n-1)*size ..< min(n*size, length)`. Each part is
  the text `RK1:<transfer id>:<n>/<total>:<Base45 of its bytes>`, which uses only QR alphanumeric characters. The
  transfer id is 6 random Crockford symbols. `n` and `total` are plain decimals; `total` is 1 to 99.
- **Base45** is RFC 9285: each 2 bytes `[a, b]` become `n = a*256 + b` written as `c + d*45 + e*45²` (3 symbols
  `c d e`), a last single byte as 2 symbols, alphabet `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:`.
- **Collecting**: a scanner keeps parts by `n`. Parts from another transfer id or with another total are refused (the
  user is told a different code was scanned). Scanning a part again is fine; the same `n` with different data is an
  error. When every `n` is in, the payload is the parts' bytes in order; its first byte must be `0x01` and it must be at
  least 45 bytes long.
- A wrong unlock code fails the tag check: "wrong unlock code". Nothing is imported.

## Importing (merge rules)

`scenarios/config-merge.json` holds the cases. Every core plans an import the same way:

1. **Fit the incoming servers to this platform.** Off the Mac, a server with an `sshConfigAlias` and a `resolved` entry
   takes `resolved`'s host, user and port, and `sshConfigAlias` and `identityFile` are dropped (`identityFile` is
   dropped on every platform but the Mac).
2. **Match** each incoming server to a local one: same id; else the same address (host compared ignoring case, port
   missing = 22, user missing = empty). Each local server matches at most one incoming server, the first.
3. Each server is then **new** (no match), **identical** (name, host, user, port, alias and key file all equal, with
   the address rules of step 2 and a missing value equal to an empty one) or a **change** listing the fields that
   differ (`name`, `host`, `user`, `port`, `sshConfigAlias`, `identityFile`). A matched server takes the document's
   sign-in, settings and secret, and a changed one also its fields, when the user leaves it on Update (the default);
   an identical one keeps its own fields as written here. Keep mine leaves the local server, its sign-in and its
   settings alone.
4. **Ids**: a server that matched keeps its local id; everything the document files under the incoming id (sign-in,
   settings, secrets) is moved to the local id. New servers keep their incoming id.
5. **Order**: local servers first, in their order, then new servers in the document's order.
6. **Sign-in and secrets** of new and updated servers come from the document where it has them; a server the
   document has no sign-in for keeps its own. Off the Mac a `system` sign-in is ignored (it names the Mac's own ssh
   setup), so the server keeps its own there or needs one.
7. **Settings** of new and updated servers: incoming `icons` and `services` entries replace the local entry with the
   same key and other local entries stay; `vulnerabilityLookup` is taken when present; `mutedAlerts` are the union.
8. **Preferences** (Apply imported or Keep mine), with the `"*"` service rules: when applied, every incoming value
   replaces the local one, except `readOnly`, which becomes `local OR incoming`: **an import can turn Read-only on,
   never off.** Kept: nothing changes.
9. **Host keys**, compared by host (ignoring case), port and type:
   - the same key already trusted: **trusted**, nothing to do;
   - the same type with a different key: **blocked**, never imported whatever the choices, shown with both
     fingerprints;
   - the address already has a trusted key of another type: **skipped** (this device already trusts that server);
   - otherwise **add**, done only when the user leaves "Trust these host keys" ticked (ticked by default for an
     encrypted file or a QR transfer, unticked for a plain file).
   A platform that keeps one key per address (iOS, Android, web) adds only the first of an address's keys in the order
   `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521`, `ssh-rsa`, then any other type
   in the document's order; the rest are skipped.
10. **Replace everything** (after the app has saved a plain backup of what is here): the servers become the
    document's, in its order and fitted to this platform, matched ones keeping their local id (rule 4) and identical
    ones their own fields; local servers
    with no match are removed (the app forgets their sign-in, secrets and settings). Sign-ins, settings and the `"*"`
    rules are the document's, not merged. Preferences are applied as in rule 8, so `readOnly` is still
    `local OR incoming`. Host keys follow rule 9 in both modes: an import never removes a trusted key and never
    replaces one.
11. **Custom icons** are added (they are named by their hash, so they cannot clash).
12. **The result**: apps save the planned document. Its `secrets` are only the imported ones, under the ids they now
    belong to; its `hostKeys` are this device's plus the added ones.

Fingerprints are `SHA256:` and the unpadded base64 of the SHA-256 of the key bytes, as `ssh-keygen -l` prints.
