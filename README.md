# eeploi-helper

The only command [eeploi](https://eeploi.com) may run as root on your server.

eeploi connects to your server as a normal user, `eeploi`. That user has no root access, except for this one file. One sudo rule allows it:

```
eeploi ALL=(root) NOPASSWD: /usr/local/sbin/eeploi-helper
```

The helper has a fixed list of subcommands. Each one checks its arguments and does one fixed thing. Anything else is refused. You can read every line that runs as root right here.

## Subcommands

Run as `sudo eeploi-helper <subcommand> [arguments]`. Content (a vhost, a certificate, a config) comes on stdin.

| Subcommand | Does |
|---|---|
| `version` | Prints the helper version |
| `nginx-test` | `nginx -t` |
| `nginx-reload` | Reloads nginx |
| `php-fpm-reload <version>` | Reloads PHP-FPM for that version, like `8.4` |
| `php-pool-write <version>` | Writes eeploi's own PHP-FPM pool (`/etc/php/<version>/fpm/pool.d/eeploi.conf`), runs as the deploy user, socket `/run/php/php<version>-fpm-eeploi.sock`. Tests the config with `php-fpm<version> -t` before the reload; on failure the old pool comes back |
| `vhost-write <domain>` | Writes the vhost for the domain from stdin |
| `vhost-read <domain>` | Prints the vhost for the domain |
| `vhost-enable <domain>` | Links the vhost into `sites-enabled` |
| `vhost-disable <domain>` | Removes the link from `sites-enabled` |
| `vhost-remove <domain>` | Removes the vhost and its link |
| `vhost-set-root <domain> <old> <new>` | Changes `root <old>;` to `root <new>;`. Both must be inside an allowed home folder |
| `vhost-set-socket <domain> <from> <to>` | Changes the exact line `fastcgi_pass unix:<from>;` to `unix:<to>;`. Only PHP-FPM sockets in `/run/php` or `/var/run/php`. Runs `nginx -t` before the reload; on failure the old vhost comes back |
| `vhost-set-cert <domain>` | Points the vhost's certificate lines to `/etc/nginx/ssl/eeploi-<domain>.crt` and `.key` |
| `ssl-csr <name>` | Makes a private key (once) and prints a certificate request |
| `ssl-write <name>` | Writes a certificate from stdin |
| `ssl-remove <name>` | Removes a certificate and its key |
| `ssl-read <domain>` | Prints the SSL include for the domain (exit 3 when there is none) |
| `ssl-include-write <domain>` | Writes the SSL include for the domain from stdin |
| `supervisor-write <program>` | Writes a Supervisor program `eeploi-*`. It must run as the calling user |
| `supervisor-remove <program>` | Removes a Supervisor program `eeploi-*` |
| `supervisor-remove-site <domain>` | Removes all eeploi Supervisor programs of a site |
| `supervisor-pause <config>` | Renames a Supervisor config to `.paused` |
| `supervisor-resume <config>` | Renames it back |
| `supervisor-update` | `supervisorctl reread` and `update` |
| `cron-write <domain>` | Writes one `schedule:run` cron line for a site. Nothing else is allowed |
| `cron-remove <domain>` | Removes that cron file |
| `crontab-backup <domain>` | Copies `/etc/crontab` to `/var/lib/eeploi/crontab/<domain>` |
| `crontab-restore <domain>` | Puts that copy back |
| `crontab-remove-lines` | Removes the exact lines from stdin from `/etc/crontab` |
| `env-install <from> <to> <owner>` | Copies a `.env` into the caller's home folder, mode `640` |
| `storage-copy <from> <to> <owner>` | Copies a `storage` folder into the caller's home folder |
| `firewall-close-22` | Closes port 22 in UFW. Only on a server eeploi created (see below) |
| `acl-nginx` | Lets the nginx user pass through the deploy user's home folder (`setfacl -m u:<nginx user>:x`). Nothing more: the folder stays `750` |
| `self-update <version>` | Installs a signed release (see below) |

Allowed home folders: `/home/ploi`, `/home/forge`, `/home/eeploi` and the deploy user's.

## Settings on the server

Two optional files, both owned by root and not writable by anyone else. The helper refuses to run when they are not.

| File | Does |
|---|---|
| `/etc/eeploi/helper.conf` | `DEPLOY_USER=<user>`, when the deploy user is not `eeploi`. Only that line and comments are allowed. The file is read, never run |
| `/etc/eeploi/new-server` | Marker written when eeploi created the server. Without it, `firewall-close-22` refuses. On a server you bring yourself, eeploi never touches the SSH port or the firewall |

The nginx user is read from the `user` line in `/etc/nginx/nginx.conf`. Without one it is `www-data`. A line the helper cannot read, two `user` lines or `root` are refused.

## Install by hand

You need `curl` and `minisign` (`apt install minisign`).

```bash
VERSION=1.0.0
curl -fLO https://github.com/eeploi/helper/releases/download/v$VERSION/eeploi-helper
curl -fLO https://github.com/eeploi/helper/releases/download/v$VERSION/eeploi-helper.minisig
minisign -Vm eeploi-helper -P RWSoGWKrJHDJoknVaEcX3dz5ew9zWZPqae2Qn2d3M+SGxNBT99NZGiLA
sudo install -o root -g root -m 755 eeploi-helper /usr/local/sbin/eeploi-helper
```

Then the sudo rule, checked by `visudo` before it goes live:

```bash
echo 'eeploi ALL=(root) NOPASSWD: /usr/local/sbin/eeploi-helper' | sudo tee /etc/sudoers.d/.eeploi > /dev/null
sudo chmod 440 /etc/sudoers.d/.eeploi
sudo visudo -cf /etc/sudoers.d/.eeploi && sudo mv /etc/sudoers.d/.eeploi /etc/sudoers.d/eeploi
```

The release key is also in `eeploi-helper` itself (`PUBKEY`). Check that both match.

## Self-update

```bash
sudo eeploi-helper self-update 1.1.0
```

1. Checks the version is a plain `x.y.z`.
2. Downloads `eeploi-helper` and `eeploi-helper.minisig` of that release from GitHub.
3. Checks the signature with the key built into the running helper. A bad signature changes nothing.
4. Checks the new file with `bash -n`, and that its `version` is the one you asked for.
5. Installs it as root, mode `755`, in one move.

Going back works the same way: `self-update` with an older version. The sudo rule never changes: it names the path, not the content.

## Dry run

`EEPLOI_HELPER_DRY_RUN=1` checks every argument and prints what the helper would run or write. It changes nothing. sudo drops the variable, so it is for tests only.

```bash
EEPLOI_HELPER_DRY_RUN=1 SUDO_USER=eeploi bash eeploi-helper php-pool-write 8.4
```

In dry-run mode only, `EEPLOI_HELPER_ETC` and `EEPLOI_HELPER_NGINX_CONF` point to test copies of `/etc/eeploi` and `nginx.conf`.

## Tests

```bash
bash tests/run.sh
```

Plain bash, no extra tools. Runs `bash -n`, `shellcheck` when installed, and the dry-run cases. CI runs it on every push.

## Security model

- **Fixed actions.** Each subcommand does one thing. There is no way to pass a command.
- **Checked input.** Domains, paths, versions, sockets and configs are checked against strict patterns. Paths must stay inside the allowed home folders, also after resolving links.
- **Called through sudo.** The helper refuses to run unless `SUDO_USER` is an allowed user.
- **Signed releases.** Every release is signed with minisign. The helper only installs a release signed with the key built into it.
- **The signing key is offline.** It never touches GitHub or eeploi.com. A hacked eeploi.com or GitHub account still cannot ship a helper your server accepts.

Found a problem? See [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
