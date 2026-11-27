# Config transfer: export, import, QR

Status: approved 2026-11-27. Stage C1 (spec and cores) is built on branch `feature/config-transfer`; C2 (Mac) and C3
(iPhone) are next. The format's exact rules are in [spec/config-transfer.md](../spec/config-transfer.md), which wins
where this page summarises.

Move a whole Rackoon setup between devices (Mac, iPhone, Android, web) and keep backups: one file format shared by
every platform, plus a QR code for moving it from a screen to a phone.

## Decisions already taken (2026-11-26)

- **Secrets never go in a QR.** A backup file may include them only when encrypted with a passphrase the user types.
  Saved sudo passwords are never exported. Re-entering an SSH password after an import is acceptable.
- **The QR carries the data itself** (compressed, encrypted, split across several codes shown in turn), unlocked with a
  short code shown beside it. No network listener and no server in between.
- **Import can merge**: servers that match ones already here are offered as updates, not duplicates.
- **First stage**: the spec and format, the Swift, Kotlin and Python cores, and the Mac and iPhone apps. Android and web
  screens come in stage 2.
- **Every later feature that saves a setting must add it to the transfer** (enforced, see "Coverage").

## What is carried

One canonical document, `rackoon-config` version 1. Its names are the same on every platform; each app maps them to its
own preference keys (`spec/config-transfer.json` holds the mapping).

| Part | Contents | In a QR | Notes |
|---|---|---|---|
| `servers` | id, name, host, user, port, in saved order | yes | Mac only: `sshConfigAlias` and `identityFile`, plus `resolved` (host/user/port from `ssh -G`) so other devices get a real address |
| `hostKeys` | per server: host, port, key type, base64 key, SHA-256 fingerprint | yes | see "Host keys" |
| `signIn` | per server: method only (`tailscale`, `key`, `password`, `sshConfig`) and a key's name | yes | no secret material |
| `preferences` | theme, highlight output, Read-only, auto Read-only, Docker unlock duration, alert notifications, terminal font size, services/files "show hidden", Dashboard "show all Docker" | yes | see "Read-only" |
| `serverSettings` | per server: icon choices, services shown/hidden, vulnerability lookup opt-in, muted alerts | yes | `osvLookupAll` sits in `preferences` |
| `customIcons` | the user's own uploaded icon images (PNG, base64) | no | too large; a QR import falls back to the automatic icon and says so |
| `secrets` | per server: SSH password, or private key (+ passphrase) | **no** | only in a passphrase-encrypted file, only when ticked |

**Never carried** (device-local by design, listed with a reason in the spec so the coverage test knows): saved sudo
passwords, cached snapshots, favicons and icon caches, the OSV answer cache, Security readings (including deeper sudo
ones), alert history and "seen" marks, the selected server, Dashboard page, start screen, window state, demo mode, the
supporter licence, web sign-in (admin password, TOTP, sessions) and Web Push subscriptions.

## Files

- **Plain** `Rackoon-<device>-<date>.rackoon`: the JSON document, readable. No `secrets` part.
- **Encrypted** (same extension): a small JSON envelope `{format, version, kdf: {name: "PBKDF2-SHA256", iterations,
  salt}, cipher: "AES-256-GCM", nonce, ciphertext}` around the compressed document. Choosing a passphrase is what makes
  the "include passwords and keys" option available. The passphrase is checked for a minimum length and never stored.

Exporting asks two things: include secrets (needs a passphrase), and on the Mac whether to include the private key
files the servers point at (`identityFile`), which is how a Mac's key reaches an iPhone.

## QR

- The document without `secrets` and `customIcons` is compressed (raw DEFLATE), encrypted with AES-256-GCM under a key
  derived from a random **unlock code**, and split into parts.
- Each part is one QR in alphanumeric mode: `RK1:<transfer id>:<n>/<total>:<Base45 data>`. Base45 (RFC 9285) fits more
  into a code than base64. Parts are kept small enough to scan reliably from a laptop screen. Several parts are shown
  one after another in a loop, and the phone collects them in any order and shows progress.
- The unlock code is 10 characters (Crockford base32, shown `XXXXX-XXXXX`) beside the codes. The phone asks for it once
  every part is in. A wrong code, or a part from a different transfer, is refused rather than guessed at.
- Why encrypt a QR with no secrets in it: it holds server addresses and trusted host keys. The code stops a photo of
  the screen from being enough, and the authenticated encryption stops a swapped QR from planting a host key.

## Importing

1. Read the file (asking for the passphrase if it is encrypted), or scan the QR and type the unlock code.
2. A preview, before anything changes:
   - **New servers**: added.
   - **Matching servers** (same id, else same host + user + port): differences are shown; choose Update or Keep mine,
     per server or for all.
   - **Identical servers**: nothing to do.
   - **Preferences**: Apply imported or Keep mine.
   - **Host keys**: listed with fingerprints. See below.
   - **Secrets**, if any: which servers get a password or key.
3. Or **Replace everything**: first saves an automatic backup of the current setup (plain, beside the app's data), then
   replaces it.

When a match has a different id, everything filed under the incoming id (icon choices, mutes, opt-ins) is moved to the
local id.

### Host keys

- A key for a server with no trusted key here is added only when the user leaves "Trust these host keys" ticked (on by
  default for an encrypted file or a QR; off by default for a plain file, which anyone could have edited).
- A key that **differs** from the one already trusted is never imported, whatever the file says. It is shown as blocked
  with both fingerprints, the same rule as a changed key at connect time.
- On the Mac, keys are appended to `~/.ssh/known_hosts` the same way the existing trust flow does it. Other platforms
  write their own `known_hosts.json`.

### Read-only

An import can turn Read-only **on**, never off. A device that is in Read-only stays so until its user switches it off.

### Sign-in after import

- A server whose secret came in an encrypted file is ready to connect.
- Otherwise its method is kept and it shows "sign-in needed" on first connect (iPhone and Android ask for the password or
  key; a Mac uses its own ~/.ssh as now).
- A Mac `identityFile` path means nothing elsewhere. Without the key in the file, the other device asks for one.

## Format rules (spec first)

- `spec/config-transfer.md`: the format in words. `spec/config-transfer.schema.json`: the document.
- `spec/config-transfer.json`: the settings catalog. Each canonical setting has a type, default, `transfer: true|false`
  (with the reason when false) and its key on Mac, iOS, Android and web.
- `spec/fixtures/config/`:
  - a full plain document from each platform;
  - an encrypted file with a published test passphrase;
  - a QR part set with a published unlock code;
  - documents from a future version: unknown fields are kept and ignored, and a newer major version is refused with a
    clear message.
- `spec/scenarios/config-merge.json`: the merge cases (new, matching by id, matching by address, identical, conflicting
  host key, Read-only on/off, id remapping), run by every core's `SharedScenarioTests`.
- `features.json`: new features `config.file` (export and import a file) and `config.qr`, done or planned per platform.

## Cores

- The format, merge planning, Base45, QR part split/join and the catalog are pure code in each core: Swift
  `RackoonCore`, Kotlin `android/core` and Python `rackoon.core`.
- Encryption and compression are injected, the same way the licence check gets its Ed25519 verifier, because
  `RackoonCore` stays Foundation-only and builds on Linux:
  - Apple: CryptoKit AES-GCM, CommonCrypto PBKDF2 and Foundation's zlib.
  - Kotlin: `javax.crypto` and `java.util.zip`.
  - Python: `cryptography`, which asyncssh already needs, plus `hashlib` and `zlib`.
- No new dependencies on Apple or Python. The Apple implementation is the small Apple-only target
  `RackoonAppleCrypto` (`AppleConfigCrypto`), which RackoonCoreTests also uses on Apple hosts. Kotlin computes PBKDF2
  over HMAC-SHA256 itself, because Android has varied in how its built-in PBKDF2 turns a passphrase into bytes.

## Coverage (the standing rule)

`tools/check-spec` scans each app's source (UserDefaults and `@AppStorage` keys on Mac and iOS, SharedPreferences
keys on Android, `preferences.json` keys on web, and every `*.json` file name each app reads or writes) and fails when
one is missing from `spec/config-transfer.json`, or when the catalog names a key the app no longer has. Every entry is
either carried (with the document part it goes in) or local (with a reason), so a new saved setting cannot be added
without deciding whether it transfers. Each core also tests that it reads the catalog's preferences with the catalog's
types (Swift keeps a copy, tested equal to the file).

## Stages

1. **C1 Spec and cores**: the format, catalog, fixtures and scenarios, then the Swift, Kotlin and Python cores passing
   them, with the coverage tests.
2. **C2 Mac**:
   - File > Export Configuration… and Import Configuration…;
   - Show as QR Code… (cycling codes plus the unlock code);
   - the import preview sheet;
   - `ssh -G` resolution for aliases;
   - reading and writing known_hosts.
3. **C3 iPhone**:
   - export and import through the Files app and the share sheet (AirDrop);
   - scan QR (camera; demo mode can inject parts so the simulator UI test runs);
   - the same preview;
   - secrets saved to the Keychain.
4. Later: Android and web screens (Android scanning needs a QR library); importing web-only settings (ntfy, webhooks)
   between web instances.

## Not planned

Live sync between devices, iCloud (needs a paid developer account), a network listener for transfers, and exporting
saved sudo passwords.
