# Releasing

For the owner. Signing always happens on your own machine, never in CI.

## Once: the signing key

1. Create the key pair:

   ```bash
   minisign -G -p minisign.pub -s ~/.minisign/eeploi-helper.key
   ```

   Use a strong passphrase. `bin/release` reads the secret key from that path; set `HELPER_KEY` to another absolute path to use another.
2. Keep the secret key offline: on an encrypted disk, with a backup on the USB recovery kit. Never in this repo, GitHub, eeploi.com or a password manager that syncs to a server.
3. Put the public key (the second line of `minisign.pub`, starting with `RW`) in three places:
   - `PUBKEY` near the top of `eeploi-helper`
   - the install command in `README.md`
   - `minisign.pub` in this repo
4. Commit. Until then `self-update` refuses to run.

## Each release

1. In one pull request, raise `VERSION` in `eeploi-helper` and move the lines under `## Unreleased` in `CHANGELOG.md` to a new heading `## <version>`, with no date (D-34 in `DECISIONS.md`): `### Breaking` first when a caller must change, then `### Added`, `### Changed` and `### Fixed`. `## Unreleased` stays on top, empty. The new version must be higher than every released one (D-35). While eeploi is in dev mode, a fix is a patch release (`1.0.1`, `1.0.2`…), so every version works.
2. Merge to `main` and wait for CI to pass.
3. In your own terminal, on an up-to-date `main`:

   ```bash
   bin/release
   ```

   It first shows what it releases: the previous version (the highest `v*` tag on GitHub), the new version, the commit and the id of the key in `minisign.pub`. Then it checks, one line each, that you're on `main`, nothing is uncommitted and `main` matches GitHub; that the version is one `self-update` installs and higher than every `v*` tag on GitHub (each part compared as a number); that `CHANGELOG.md` starts with an empty `## Unreleased` and then `## <version>` with its lines; and that CI's run for the push of exactly this commit to `main` passed as a whole, with its job `test` (a pull request's run doesn't count); and that the repository has immutable releases on. CI's job runs shellcheck and the tests, so they don't run again here. Last, it shows what changed since the previous release: the number of commits, the lines of `eeploi-helper` added and removed, and the commits' subjects when there are 10 or fewer (`git log --oneline v<previous>..` shows more). A check that fails stops with ✗ and why; nothing is signed. Colour only in a terminal.

   Then it asks `Sign <version>?`. After your `y`, minisign asks for your key password and signs `eeploi-helper` with the trusted comment `eeploi-helper <version>`, and the signature is checked against `minisign.pub`. Before anything goes to GitHub it stops, with nothing pushed, if the folder moved off the checked commit or `eeploi-helper` is no longer the signed file (another session pulling `main`, say). It creates the GitHub release as a draft on the checked commit, with `eeploi-helper` and `eeploi-helper.minisig` and no tag yet. It downloads the draft's files again and checks both against the signed file and `minisign.pub`. Only then does it publish the draft: publishing creates the `v<version>` tag on the checked commit (a lightweight tag, made by GitHub) and makes the release immutable. Last, it checks that the release is immutable with only those two files, downloads and checks them once more, and checks that the tag is on the checked commit. It ends with the released version, the tag and its commit, the key id and the SHA-256 of `eeploi-helper`.

   Tags and releases never change (D-26 in `DECISIONS.md`): when the tag or a published release for this version already exists, the checks stop and ask for a new version. A run that stops before publishing leaves at most a draft, with no tag, and says so. Check the draft, delete it (`gh release delete v<version> -R eeploi/helper`) and run `bin/release` again: until the draft is gone, the checks stop on it. A run that stops after publishing has released the version.

   `bin/release --check` shows the same and runs only the checks, then stops before `Sign <version>?`: no key, no signing, nothing published.
4. Pin the new version and its SHA-256 in eeploi.com.
5. Check on a test server: `sudo eeploi-helper self-update <version>`, then `sudo eeploi-helper version`. A server already on the same version reinstalls instead: `self-update` only takes a newer one.

## A new key

A new public key ships inside a release signed with the old key. Servers update to that release, and from then on trust the new key. Keep the old secret key until every server has updated.
