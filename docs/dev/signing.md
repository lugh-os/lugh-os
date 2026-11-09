# Signing the Lugh apt repository

> Status: **Phase 0** · Related: ADR-003, [build-and-release](../specs/build-and-release.md) §Signing, NFR-4

Every Lugh apt repository is signed. apt refuses unsigned metadata, and the
signature is how a Lugh install knows that an update really comes from us.
This page covers the key layout, how to create the keys, how CI signs, and how
to rotate or revoke a key.

## Key layout

| Key | Capability | Where it lives | Used for |
|---|---|---|---|
| **Primary key** `Lugh Archive Signing Key` | Certify (`C`) only | Offline: an encrypted USB stick plus a paper backup, held by the founder. Never on a networked machine. | Creating, extending and revoking subkeys. Nothing else. |
| **dev/beta signing subkey** | Sign (`S`) | CI secret `LUGH_REPO_GPG_KEY` (secret subkey only, primary is a stub) | `lugh1-dev` and `lugh1-beta` metadata, nightly ISOs. Rotated yearly. |
| **stable signing subkey** (later phase) | Sign (`S`) | Hardware token (OpenPGP card), manual release step | `lugh1` stable metadata, release ISOs, `SHA256SUMS`. |
| **Dev key** `Lugh DEV KEY - NOT FOR RELEASE` | Certify + sign subkey | `out/dev-key/` on your machine, generated automatically | Local builds only. |

**Algorithm: Ed25519** for the primary and the subkeys. Debian 13's apt verifies
signatures with `sqv` (Sequoia), which accepts Ed25519 and RSA alike; Ed25519
keys and signatures are small and fast. The Phase 0 check publishes a repo
signed with an Ed25519 subkey and runs `apt-get update` against it in a
`debian:trixie` container, so this is tested, not assumed.

Apt trusts the **primary** key's fingerprint (the public key file contains the
primary and all its public subkeys), so rotating a subkey does not need any
change on users' machines as long as the new subkey ships before the old one
stops signing.

## Where the public key goes

- The repo publishes it as `lugh.asc` at its root (`out/repo/lugh.asc` locally).
- The ISO installs it to **`/etc/apt/keyrings/lugh.asc`** and the source refers to it:

  ```
  # /etc/apt/sources.list.d/lugh.sources
  Types: deb
  URIs: https://repo.lugh.example/
  Suites: trixie
  Components: main
  Signed-By: /etc/apt/keyrings/lugh.asc
  ```

  The real URL and suite names (`lugh1-dev`, `lugh1-beta`, `lugh1`) arrive in
  Phase 7. Phase 0 uses suite `trixie`, component `main`.
- The key is never added to the global `trusted.gpg.d/`: `Signed-By` scopes it to
  the Lugh repository only.

## Creating the keys (once, offline)

Do this on an air-gapped machine (for example a live USB with networking
disabled), with the encrypted USB stick mounted at `/media/lugh-key`.

```sh
export GNUPGHOME=/media/lugh-key/gnupg
mkdir -m 700 -p "$GNUPGHOME"

# 1. Primary key: certify only, 5 years. Pick a long passphrase and write it
#    down with the paper backup.
gpg --quick-generate-key "Lugh Archive Signing Key <archive@lugh.example>" \
    ed25519 cert 5y
FPR=$(gpg --with-colons --list-secret-keys archive@lugh.example \
      | awk -F: '$1=="fpr"{print $10; exit}')
echo "$FPR"   # record this fingerprint in the release notes and on the website

# 2. dev/beta signing subkey: sign only, 1 year.
gpg --quick-add-key "$FPR" ed25519 sign 1y

# 3. Revocation certificate for the primary (gpg also writes one to
#    $GNUPGHOME/openpgp-revocs.d/). Print it and store it with the paper backup.
gpg --output "lugh-primary-revoke.asc" --gen-revoke "$FPR"

# 4. Paper backup of the primary secret key.
gpg --export-secret-keys "$FPR" | paperkey --output lugh-primary-paperkey.txt

# 5. Public key, to commit as the reference copy and ship in the ISO.
gpg --armor --export --export-options export-minimal "$FPR" > lugh.asc
```

### Exporting the subkey for CI

CI must hold only the signing subkey, never the primary. Export the secret
subkeys (the primary becomes a stub, shown as `sec#`), and give the exported
copy its own passphrase or none: CI secrets are already encrypted at rest and
the key is scoped to the `release` environment.

```sh
SUB=$(gpg --with-colons --list-keys "$FPR" \
      | awk -F: '$1=="sub" && $12 ~ /s/ && $2 !~ /[erd]/ {getline; print $10}' | tail -1)

# Work on a copy so the offline keyring keeps its passphrase.
TMP=$(mktemp -d) && cp -a "$GNUPGHOME"/. "$TMP"/
GNUPGHOME=$TMP gpg --passwd "$FPR"          # optional: set an empty passphrase on the copy
GNUPGHOME=$TMP gpg --armor --export-secret-subkeys "${SUB}!" > lugh-signing-subkey.asc
rm -rf "$TMP"

# Check: the primary must be a stub (sec#), the subkey present (ssb).
CHECK=$(mktemp -d)
GNUPGHOME=$CHECK gpg --import lugh-signing-subkey.asc
GNUPGHOME=$CHECK gpg --list-secret-keys
rm -rf "$CHECK"
```

Store the content of `lugh-signing-subkey.asc` as the GitHub Actions secret
**`LUGH_REPO_GPG_KEY`** in the `release` environment (required reviewers). If you
kept a passphrase on the exported copy, also store it as
`LUGH_REPO_GPG_PASSPHRASE`. Then shred the file:
`shred -u lugh-signing-subkey.asc`.

## How the build signs

`scripts/repo-publish.sh` (what `make repo` runs) does the signing, inside the
build container:

1. If **`LUGH_REPO_GPG_KEY`** is set, it imports that ASCII-armored secret
   (sub)key into a throwaway `GNUPGHOME` in the container's `/tmp` (never in the
   checkout) and signs with it. `LUGH_REPO_GPG_PASSPHRASE` is used if set.
   `scripts/lib/container.sh` passes all `LUGH_*` variables into the container.
2. Otherwise it uses the **dev key**: it generates `Lugh DEV KEY - NOT FOR
   RELEASE` once into `out/dev-key/` (Ed25519 primary + signing subkey, no
   passphrase) and prints a large warning on every run.
3. aptly signs `Release` (`Release.gpg` and `InRelease`), the public key is
   exported to `out/repo/lugh.asc`, and the script checks that `InRelease`
   verifies against that file before it exits.

CI example:

```yaml
- name: Publish the repo
  env:
    LUGH_REPO_GPG_KEY: ${{ secrets.LUGH_REPO_GPG_KEY }}
  run: make repo
```

### The dev key

> ⚠️ **A repo or ISO signed with the dev key is for your machine only.**
> Never upload, mirror or hand out anything signed with it. Its secret key sits
> unencrypted in `out/dev-key/secret.asc`, and anyone with your checkout can
> sign with it.

- To make a fresh one, delete `out/dev-key/` (or `out/`); the next
  `make repo` generates a new key. ISOs built before that trust the old key.
- PR builds in CI also use a dev key (no secrets on PRs). Only `main` and
  release jobs get `LUGH_REPO_GPG_KEY`.

## Verifying by hand

```sh
gpg --show-keys out/repo/lugh.asc                         # who signed
gpg --no-default-keyring --keyring ./lugh.kbx --import out/repo/lugh.asc
gpg --no-default-keyring --keyring ./lugh.kbx --verify out/repo/dists/trixie/InRelease
```

## Rotating the signing subkey (yearly, or after a suspected leak)

Start about a month before the current subkey expires, so the new public key
reaches users before the old subkey stops being used.

1. Offline, with the primary key: add a new signing subkey.
   ```sh
   gpg --quick-add-key "$FPR" ed25519 sign 1y
   ```
2. Export the updated public key (it now has both subkeys) to `lugh.asc`, and
   ship it: update the reference copy in the repo, publish it at the repo root,
   and release a `lugh-archive-keyring` update (planned package) that installs it
   to `/etc/apt/keyrings/lugh.asc`. Users get it through the old, still-valid key.
3. Wait until that update has been out for a release cycle.
4. Export the new secret subkey (see above, with the new subkey's fingerprint
   and `!`) and replace the `LUGH_REPO_GPG_KEY` secret.
5. Let the old subkey expire, or revoke it if it is no longer needed:
   `gpg --edit-key "$FPR"` → `key N` → `revkey` → `save`, then export and ship
   the public key again.

To extend instead of rotate (same subkey, later expiry):
`gpg --quick-set-expire "$FPR" 1y "<subkey fingerprint>"`, then ship the
refreshed public key. No secret change is needed in CI.

## Revocation

**Signing subkey leaked or CI compromised:**
1. Remove the `LUGH_REPO_GPG_KEY` secret at once and pause publishing.
2. Offline: revoke the subkey (`revkey` as above, reason "key has been
   compromised"), add a new signing subkey.
3. Ship the updated public key (revoked old subkey + new subkey) as above.
   Because apt trusts the primary key, signatures from the revoked subkey stop
   verifying once users have the updated key.
4. Re-sign and republish every suite with the new subkey, and publish an
   advisory with the dates the leaked key could have been misused.

**Primary key lost or compromised** (the worst case):
1. Publish the revocation certificate you printed at creation:
   `gpg --import lugh-primary-revoke.asc && gpg --armor --export "$FPR"`.
2. Create a completely new primary key and subkeys as above.
3. Users must replace `/etc/apt/keyrings/lugh.asc` themselves (a signed
   announcement on the website and a final update signed by the old key if it
   is only lost, not compromised). This is why the primary never leaves the
   offline media.

## Checklist

- [ ] Primary key generated offline, fingerprint published.
- [ ] Paper backup and revocation certificate printed and stored separately.
- [ ] `LUGH_REPO_GPG_KEY` holds the subkey only (`sec#` after import).
- [ ] Subkey expiry in the team calendar, one month ahead.
- [ ] No repo or ISO signed with `Lugh DEV KEY - NOT FOR RELEASE` was ever published.
