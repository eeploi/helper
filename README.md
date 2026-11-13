# eeploi-helper

The only command [eeploi](https://eeploi.com) may run as root on your server.

eeploi connects to your server as a normal user, `eeploi`. That user has no root access, except for this one file. One sudo rule allows it:

```
eeploi ALL=(root) NOPASSWD: /usr/local/sbin/eeploi-helper
```

The helper has a fixed list of subcommands. Each one checks its arguments and does one fixed thing. Anything else is refused. You can read every line that runs as root right here.

## Subcommands

Run as `sudo eeploi-helper <subcommand> [arguments]`. Only a certificate, a worker command, cron lines and a database password come on stdin, and each is checked. Files a root service reads (vhosts, Supervisor configs) are built by the helper from checked arguments, never taken from the caller. Logs those services open as root go to `/var/log`, never to a folder the caller can write.

| Subcommand | Does |
|---|---|
| `version` | Prints the helper version |
| `nginx-test` | `nginx -t` |
| `nginx-reload` | Reloads nginx |
| `php-fpm-reload <version>` | Reloads PHP-FPM for that version, like `8.4` |
| `php-pool-write <version>` | Writes eeploi's own PHP-FPM pool (`/etc/php/<version>/fpm/pool.d/eeploi.conf`), runs as the deploy user, socket `/run/php/php<version>-fpm-eeploi.sock`. Tests the config with `php-fpm<version> -t` before the reload; on failure the old pool comes back |
| `vhost-write <domain> <socket>` | Writes eeploi's vhost for the domain: HTTPS only, root `/home/<caller>/<domain>/current/public`, certificate `/etc/nginx/ssl/<domain>.crt`, logs in `/var/log/nginx`, PHP through the given PHP-FPM socket |
| `vhost-backup <domain>` | Copies the vhost and its SSL include to `/var/lib/eeploi/nginx/<domain>` (root only), before a take-over changes them |
| `vhost-restore <domain>` | Puts that copy back |
| `vhost-enable <domain>` | Links the vhost into `sites-enabled` |
| `vhost-disable <domain>` | Removes the link from `sites-enabled` |
| `vhost-remove <domain>` | Removes the vhost and its link |
| `vhost-set-root <domain> <old> <new>` | Changes `root <old>;` to `root <new>;`. Both must be inside an allowed home folder |
| `vhost-set-socket <domain> <from> <to>` | Changes the exact line `fastcgi_pass unix:<from>;` to `unix:<to>;`. Only PHP-FPM sockets in `/run/php` or `/var/run/php`. Runs `nginx -t` before the reload; on failure the old vhost comes back |
| `vhost-set-cert <domain>` | Points the vhost's certificate lines to `/etc/nginx/ssl/eeploi-<domain>.crt` and `.key` |
| `ssl-csr <name>` | Makes a private key (once, mode `600` from the start) and prints a certificate request |
| `ssl-write <name>` | Writes a certificate from stdin. Only one PEM certificate is accepted |
| `ssl-remove <name>` | Removes a certificate and its key |
| `supervisor-write <program> <directory> <processes>` | Writes a Supervisor program `eeploi-*` with the one-line command from stdin. Runs as the calling user, in a folder in their home, 1 to 32 processes, log in `/var/log/supervisor` |
| `supervisor-remove <program>` | Removes a Supervisor program `eeploi-*` |
| `supervisor-remove-site <domain>` | Removes all eeploi Supervisor programs of a site |
| `supervisor-pause <config>` | Renames a Supervisor config to `.paused` |
| `supervisor-resume <config>` | Renames it back |
| `supervisor-update` | `supervisorctl reread` and `update` |
| `cron-write <domain>` | Writes one `schedule:run` cron line for a site. Nothing else is allowed |
| `cron-remove <domain>` | Removes that cron file |
| `crontab-remove-lines <domain>` | Removes the exact lines from stdin from `/etc/crontab` and keeps them in `/var/lib/eeploi/crontab/<domain>`. Only jobs that run as `ploi` or `forge` on a path in their home |
| `crontab-restore <domain>` | Adds those lines back, once each. Other changes to `/etc/crontab` stay |
| `env-install <from> <to> <owner>` | Copies a `.env` from `/home/ploi` or `/home/forge` (the source must end in `/.env`, also after resolving links) into the caller's home folder, mode `640`. Root only reads; the caller writes the copy |
| `storage-copy <from> <to> <owner>` | Copies a `storage` folder from `/home/ploi` or `/home/forge` (the source must end in `/storage`, also after resolving links) into the caller's home folder. Root only reads; the caller unpacks it |
| `db-create <engine> <name> <user> <socket\|password>` | Creates a database and its user on the local MySQL, MariaDB or Postgres. `socket`: the user logs in over the socket as the Unix user of the same name, with no password. `password`: password login, with the password from stdin. The user gets that one database, nothing else. See [Databases](#databases) |
| `firewall-close-22` | Closes port 22 in UFW. Only on a server eeploi created (see below) |
| `acl-nginx` | Lets the nginx user pass through the deploy user's home folder (`setfacl -m u:<nginx user>:x`), and installs the `acl` package first when `setfacl` is missing. Nothing more: the folder stays `750` |
| `self-update <version>` | Installs a signed release (see below). Only a newer one |

Allowed home folders: `/home/ploi`, `/home/forge`, `/home/eeploi` and the deploy user's.

## Settings on the server

Two optional files, both owned by root and not writable by anyone else. The helper refuses to run when they are not.

| File | Does |
|---|---|
| `/etc/eeploi/helper.conf` | `DEPLOY_USER=<user>`, when the deploy user is not `eeploi`. Only that line and comments are allowed. The file is read, never run |
| `/etc/eeploi/new-server` | Marker written when eeploi created the server. Without it, `firewall-close-22` refuses. On a server you bring yourself, eeploi never touches the SSH port or the firewall |

The nginx user is read from the `user` line in `/etc/nginx/nginx.conf`. Without one it is `www-data`. A line the helper cannot read, two `user` lines or `root` are refused.

## Databases

```bash
sudo eeploi-helper db-create pgsql shop_example shop_example socket
echo "$password" | sudo eeploi-helper db-create pgsql shop_example shop_example password
```

- **Engine:** `mysql`, `mariadb` or `pgsql`. The helper checks the server runs the one you name.
- **Names:** database and user are a lowercase letter, then `a-z`, `0-9` or `_`, at most 32. No hyphens: a name never needs quoting. eeploi names a site's Unix user after its domain, every other character as `_` (`shop.example` gives `shop_example`), and uses that name for the database user and the database too. `mysql`, `information_schema`, `performance_schema`, `sys`, `postgres`, `template0`, `template1`, `root` and anything starting with `pg_` are refused.
- **Two ways in,** named by the fourth argument, which is required. Anything else is refused.
  - **`socket`:** the user has no password at all. Only processes running as the Unix user of the same name get in, over the local socket. Postgres: a role without a password (peer auth). MariaDB: `IDENTIFIED VIA unix_socket`. MySQL: `IDENTIFIED WITH auth_socket`. The default for every site eeploi creates; nothing is stored, and the site's `.env` has no `DB_PASSWORD`. Stdin is ignored: it is never read, so an open stdin can't make the helper wait.
  - **`password`:** the password comes on stdin. For a site that already has a password, or a database reached over TCP. Nothing on stdin, a lone newline, a terminal or an invalid password is refused: it never falls back to socket login.
- **The Unix user (socket login):** must exist (`id -u`), and must be a site's own user: not a system user (uid below 1000), and not the deploy user, `eeploi`, `ploi` or `forge`, which run more than one site.
- **The auth_socket plugin (MySQL, socket login):** Ubuntu's MySQL installs it when root has no password. When it is not active, the helper installs it first (`INSTALL PLUGIN auth_socket SONAME 'auth_socket.so'`), the one plugin shipped with MySQL for this. MariaDB has `unix_socket` built in and on; when it is not active, the helper refuses.
- **Password:** on stdin only, 16 to 128 of `A-Z a-z 0-9 . _ ~ + / = -`. Never an argument, never in the system log, never in a file, never printed. The SQL goes to the client on stdin, so it is on no command line. The session turns off the server's statement logs first (`sql_log_off`; for Postgres `log_statement`, `log_min_error_statement`, `log_min_duration_statement`, `pg_stat_statements.track_utility`). On an error only the error lines are shown, without the password.
- **How:** MySQL and MariaDB as root through the local socket. Postgres as the `postgres` user (`runuser -u postgres -- psql`). Both with a clean environment, so no option file or variable from the caller counts.
- **What it makes:** MySQL and MariaDB: the user `'<user>'@'localhost'`, the database (`utf8mb4`, `utf8mb4_unicode_ci`) and `ALL PRIVILEGES` on that database only. With password login the same user on `127.0.0.1` too, with the same password and grant, so Laravel's default `DB_HOST=127.0.0.1` works without a name lookup. Socket login stays on `localhost` only: a socket has no IP. Postgres: a login role without any other rights (`NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`), the database owned by it (`UTF8`), closed to `PUBLIC`.
- **Already there:** both there with that grant (Postgres: that owner) and the same way in is a success that changes nothing: `exists: …, nothing changed (socket login)`. A user that exists keeps its password: `created: … (password login, the user existed, its password is unchanged)`. A user that exists never gets a `127.0.0.1` user: the password on stdin could be anyone's. So a password user from 1.0.0 stays on `localhost` only: `created: … (password login, the user existed on localhost only, its password is unchanged)`.
- **Refused:** a database another user has rights on, a database that exists but is not the user's, a user with global rights (Postgres: role attributes or role memberships), a user with rights on another database, a user that exists with the other way in (`user … exists with password login, not socket login`): it is never switched, a user on `127.0.0.1` for socket login, and a user on `127.0.0.1` without one on `localhost`.

Every refusal and error exits with `64` and one line on stderr, like the other subcommands.

## Install by hand

You need `curl` and `minisign` (`apt install minisign`).

```bash
VERSION=1.0.1
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

1. Checks the version is a plain `x.y.z`, and newer than the installed one (compared by number: `1.0.10` is newer than `1.0.9`). The same or an older version is refused.
2. Downloads `eeploi-helper` and `eeploi-helper.minisig` of that release from GitHub.
3. Checks the signature with the key built into the running helper. A bad signature changes nothing.
4. Checks the new file with `bash -n`, and that its `version` is the one you asked for.
5. Installs it as root, mode `755`, in one move.

Going back, or installing the same version again, is not possible: an older release may still have a bug a newer one fixed. The sudo rule never changes: it names the path, not the content.

## Dry run

`EEPLOI_HELPER_DRY_RUN=1` checks every argument and prints what the helper would run or write. It changes nothing. sudo drops the variable, so it is for tests only.

```bash
EEPLOI_HELPER_DRY_RUN=1 SUDO_USER=eeploi bash eeploi-helper php-pool-write 8.4
```

In dry-run mode only, `EEPLOI_HELPER_ETC` and `EEPLOI_HELPER_NGINX_CONF` point to test copies of `/etc/eeploi` and `nginx.conf`, and `EEPLOI_HELPER_DB_STATE` to a file with what `db-create`'s checks would find (`key=count` lines). A dry run of `db-create` prints the SQL with `<password>` in place of the password. A `uid=<n>` or `uid=none` line in that file stands in for `id -u <user>` (without one: `1001`).

## Tests

```bash
bash tests/run.sh
```

Plain bash, no extra tools. Runs `bash -n`, `shellcheck` when installed, and the dry-run cases. CI runs it on every push.

## Security model

- **Fixed actions.** Each subcommand does one thing. There is no way to pass a command.
- **Checked input.** Domains, paths, versions, sockets and configs are checked against strict patterns. Paths must stay inside the allowed home folders, also after resolving links.
- **Called through sudo.** The helper refuses to run unless `SUDO_USER` is an allowed user.
- **Fixed environment.** `PATH`, `TMPDIR`, `HOME` (`/root`), the locale (`LC_ALL=C`) and the umask are set by the helper, not taken from the caller. `curl` reads no curlrc.
- **Signed releases.** Every release is signed with minisign. The helper only installs a release signed with the key built into it.
- **The signing key is offline.** It never touches GitHub or eeploi.com. A hacked eeploi.com or GitHub account still cannot ship a helper your server accepts.

Found a problem? See [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
