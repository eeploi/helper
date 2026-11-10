# Releasing

For the owner. Signing always happens on your own machine, never in CI.

## Once: the signing key

1. Create the key pair:

   ```bash
   minisign -G -p minisign.pub -s ~/.minisign/minisign.key
   ```

   Use a strong passphrase.
2. Keep the secret key offline: on an encrypted disk, with a backup on the USB recovery kit. Never in this repo, GitHub, eeploi.com or a password manager that syncs to a server.
3. Put the public key (the second line of `minisign.pub`, starting with `RW`) in three places:
   - `PUBKEY` near the top of `eeploi-helper`
   - the install command in `README.md`
   - `minisign.pub` in this repo
4. Commit. Until then `self-update` refuses to run.

## Each release

1. Update `VERSION` in `eeploi-helper` and add the entry in `CHANGELOG.md` (with the date). While eeploi is in dev mode, `VERSION` stays `1.0.0` and a release replaces the files of `v1.0.0`.
2. Merge to `main` and wait for CI to pass.
3. In your own terminal, on an up-to-date `main`:

   ```bash
   bin/release
   ```

   It checks that you're on `main`, nothing is uncommitted, `main` matches GitHub, shellcheck and the tests pass, and CI on that commit is green. Then minisign asks for your key password and signs `eeploi-helper` with the trusted comment `eeploi-helper <version>`, and the signature is checked against `minisign.pub`. After you confirm, it creates the `v<version>` tag (or moves it, after saying so, when the same version is released again), uploads `eeploi-helper` and `eeploi-helper.minisig` to the GitHub release, downloads them again and checks both against this file and `minisign.pub`.

   `bin/release --check` runs only the checks: no key, no signing, nothing published.
4. Vendor the release into eeploi.com (`resources/helper/`); its pinned SHA-256 follows the file.
5. Check on a test server: `sudo eeploi-helper self-update <version>`, then `sudo eeploi-helper version`. A server already on the same version reinstalls instead: `self-update` only takes a newer one.

## A new key

A new public key ships inside a release signed with the old key. Servers update to that release, and from then on trust the new key. Keep the old secret key until every server has updated.
