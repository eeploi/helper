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

1. Update `VERSION` in `eeploi-helper` and add the entry in `CHANGELOG.md` (with the date).
2. Run the tests: `bash tests/run.sh`.
3. Commit, then tag and push:

   ```bash
   git tag -s v1.2.3 -m v1.2.3
   git push origin main v1.2.3
   ```

4. Wait for CI to pass on the tag.
5. Build: the release file is `eeploi-helper` from the tag, as is.

   ```bash
   git checkout v1.2.3
   EEPLOI_HELPER_DRY_RUN=1 SUDO_USER=eeploi bash eeploi-helper version   # prints 1.2.3
   ```

6. Sign:

   ```bash
   minisign -Sm eeploi-helper -s ~/.minisign/minisign.key -t "eeploi-helper 1.2.3"
   minisign -Vm eeploi-helper -p minisign.pub
   ```

7. Create the GitHub release for the tag and upload both files, with these exact names:
   - `eeploi-helper`
   - `eeploi-helper.minisig`
8. Check on a test server: `sudo eeploi-helper self-update 1.2.3`, then `sudo eeploi-helper version`.

## A new key

A new public key ships inside a release signed with the old key. Servers update to that release, and from then on trust the new key. Keep the old secret key until every server has updated.
