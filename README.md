# eeploi-helper

The only command [eeploi](https://eeploi.com) may run as root on your server.

eeploi connects to your server as a normal user, `eeploi`. That user has no root access, except for this one file. One sudo rule allows it:

```
eeploi ALL=(root) NOPASSWD: /usr/local/sbin/eeploi-helper
```

The helper has a fixed list of subcommands. Each one checks its arguments and does one fixed thing. Anything else is refused. You can read every line that runs as root right here.

## Subcommands

Run as `sudo eeploi-helper <subcommand> [arguments]`. Only a certificate, a worker command, cron lines, a database password and the script for `run-as` come on stdin, and each is checked. Files a root service reads (vhosts, PHP-FPM pools, Supervisor configs, cron files, Redis units and configs) are built by the helper from checked arguments, never taken from the caller. Logs those services open as root go to `/var/log`, never to a folder the caller can write.

Every site runs as its own Linux user, a site user, with its home in `/srv/eeploi/<user>`. See [Site users](#site-users). `<user>` below is always a site user.

| Subcommand | Does |
|---|---|
| `version` | Prints the helper version |
| `nginx-test` | `nginx -t` |
| `nginx-reload` | Reloads nginx |
| `php-fpm-reload <version>` | Reloads PHP-FPM for that version, like `8.4` |
| `site-user-create <user> <domain>` | Makes the site user for a domain: the registry file, the user and its group, and its home `/srv/eeploi/<user>` (`750`, the nginx user may pass through). Called again for the same user and domain, it changes nothing. Deploy user only |
| `run-as <user>` | Runs the script from stdin with `bash` as the site user, in a clean environment. Nothing goes on the command line. Deploy user only |
| `releases-own <user>` | Gives the site's `releases` folder, `/srv/eeploi/<user>/<domain>/releases` with the domain from the registry, and every folder and single-link file in it that root or the deploy user owns back to the site user, in one walk (`find -depth … -execdir chown -h`, so links are changed themselves and never followed, a folder's files come before the folder, and other users' files and files with more than one link stay as they are). Runs from inside the site's folder, which may not be a link, and only with `fs.protected_hardlinks` on. Deploy user only |
| `php-pool-write <version> <user>` | Writes the site's PHP-FPM pool (`/etc/php/<version>/fpm/pool.d/eeploi-<user>.conf`), runs as the site user, socket `/run/php/php<version>-fpm-<user>.sock` owned by the nginx user with mode `0600`, so only that user may open it, not its group. Also writes `conf.d/90-eeploi.ini` with `opcache.validate_permission = 1`. Tests the config with `php-fpm<version> -t` before the reload; on failure the old files come back. One pool per site: when the registry lists the site's pool for another PHP version, that pool goes once the new one passes its test, the old version is tested and reloaded too, and on a failed test both pools come back. Pools of other panels are never touched |
| `redis-create <user> [<mb>]` | Prepares the site's own Redis, stopped: see [Redis per site](#redis-per-site). Deploy user only |
| `redis-start <user>` | Starts the site's Redis and keeps it on after a reboot (`systemctl enable --now`). Deploy user only |
| `redis-stop <user>` | Stops it and keeps it off (`systemctl disable --now`). Its data stays. Deploy user only |
| `vhost-write <domain> <user> <php-version>` | Writes eeploi's vhost for the domain of that site user: HTTPS only, root `/srv/eeploi/<user>/<domain>/current/public`, certificate `/etc/nginx/ssl/<domain>.crt`, logs in `/var/log/nginx`, PHP through the site's own socket. nginx follows a link in the site only when the link and its target have the same owner (`disable_symlinks if_not_owner from=/srv/eeploi/<user>`) |
| `vhost-backup <domain>` | Copies the vhost and its SSL include to `/var/lib/eeploi/nginx/<domain>` (root only), before a take-over changes them |
| `vhost-restore <domain>` | Puts that copy back |
| `vhost-enable <domain>` | Links the vhost into `sites-enabled` |
| `vhost-disable <domain>` | Removes the link from `sites-enabled` |
| `vhost-remove <domain>` | Removes the vhost and its link. Every check runs before anything is removed |
| `vhost-set-root <domain> <old> <new>` | Changes the vhost's one `root <old>;` line to `root <new>;`. Both must be inside an allowed home folder. A root in a site user's home must be in the folder of that user's own domain, `/srv/eeploi/<user>/<domain>/`, and gets `disable_symlinks if_not_owner from=/srv/eeploi/<user>;` right after it, once. That root line must sit at the top level of a server block that listens on port 443 (not inside a `location` or `if`), the vhost may have no `disable_symlinks` line of its own, and no line may combine a quote with `{`, `}` or `#`; otherwise it is refused. Moved back to a panel home, eeploi's `disable_symlinks` line goes. Every `include` in the vhost, and in what it includes, must be in `/etc/nginx` (a relative one counts from there), and so must every file an `ssl_` or `auth_` directive names, matched by pattern so the `proxy_`, `grpc_` and `uwsgi_` ones and later ones count too (certificates, keys, `ssl_crl`, `ssl_dhparam`, `ssl_key_log`, every `…ssl_…_file` and `auth_…_file`); every `access_log` and `error_log` must be in `/var/log/nginx`. Each of those files and every folder up to there must be root-owned and not writable by group or others, and a log may not be a link; otherwise it is refused. A temp or cache path (any `…_temp_path` or `…_cache_path`) and any njs, Perl, XSLT, GeoIP or Lua directive is refused. A path in one pair of quotes is read without them. A line with a quote and a `#`, an open quote, or a `#` inside a word is refused. Words split on a carriage return too, as in nginx. Runs `nginx -t`; on failure the old vhost comes back |
| `vhost-set-socket <domain> <from> <to>` | Changes the exact line `fastcgi_pass unix:<from>;` to `unix:<to>;`. Only PHP-FPM sockets in `/run/php` or `/var/run/php`. `<to>` is the pool of the site user listed for that domain. `<from>` may also be a socket the vhost still uses: the default one per version, `php<version>-fpm-eeploi.sock` from 1.0.1, or a panel's pool per user; never another site user's. The vhost's includes, logs and files are checked as for `vhost-set-root`. Runs `nginx -t`; on failure the old vhost comes back. It doesn't reload nginx: the caller runs `nginx-reload` once, after the whole swap. Going back to a panel's socket is `vhost-restore` |
| `vhost-set-cert <domain>` | Points the vhost's certificate lines to `/etc/nginx/ssl/eeploi-<domain>.crt` and `.key` |
| `ssl-csr <name>` | Makes a private key (once, mode `600` from the start) and prints a certificate request |
| `ssl-write <name>` | Writes a certificate from stdin. Only one PEM certificate is accepted |
| `ssl-remove <name>` | Removes a certificate and its key |
| `supervisor-write <program> <user> <directory> <processes>` | Writes a Supervisor program `eeploi-<domain>-<name>` with the one-line command from stdin. `<name>` is `a-z`, `0-9` and `-`, so no dot; a name that also fits another listed domain is refused. Runs as the site user, in a folder under `/srv/eeploi/<user>/<domain>/`, 1 to 32 processes. The log goes to `/var/log/supervisor/eeploi/<user>/`, a folder owned by root with group `<user>` (`750`), so a site reads only its own worker logs. A `%` in the command is refused |
| `supervisor-remove <program>` | Removes a Supervisor program `eeploi-*` |
| `supervisor-remove-site <domain>` | Removes the Supervisor programs the site's registry lists, and their `.paused` copies |
| `supervisor-pause <config>` | Renames a Supervisor config to `.paused` |
| `supervisor-resume <config>` | Renames it back |
| `supervisor-update` | `supervisorctl reread` and `update` |
| `cron-write <user>` | Writes one line to `/etc/cron.d/eeploi-<user>`: `* * * * * <user> php[<version>] /srv/eeploi/<user>/<domain>/current/artisan schedule:run > /dev/null 2>&1`. Nothing else is allowed |
| `cron-remove <user>` | Removes that cron file |
| `crontab-remove-lines <domain>` | Removes the exact lines from stdin from `/etc/crontab` and keeps them in `/var/lib/eeploi/crontab/<domain>`. Only jobs that run as `ploi` or `forge` on a path in their home |
| `crontab-restore <domain>` | Adds those lines back, once each. Other changes to `/etc/crontab` stay |
| `env-install <from> <to> <owner>` | Copies a `.env` from `/home/ploi` or `/home/forge` (the source must end in `/.env`, also after resolving links) into the home of the site user `<owner>`, mode `640`. `ploi` or `forge` reads the source, the site user writes the copy; root opens neither |
| `storage-copy <from> <to> <owner>` | Copies a `storage` folder from `/home/ploi` or `/home/forge` (the source must end in `/storage`, also after resolving links) into the home of the site user `<owner>`. `ploi` or `forge` reads the source, the site user unpacks it; root opens neither |
| `db-create <engine> <name> <user> <socket\|password>` | Creates a database and its user on the local MySQL, MariaDB or Postgres. `socket`: the user logs in over the socket as the site user of the same name, with no password. `password`: password login, with the password from stdin. The user gets that one database, nothing else. See [Databases](#databases) |
| `firewall-close-22` | Closes port 22 in UFW. Only on a server eeploi created (see below) |
| `self-update <version>` | Installs a signed release (see below). Only a newer one |
| `recipe-run <version> <provider>` | Runs the `always` steps of a signed [eeploi recipes](https://github.com/eeploi/recipes) release that are new or changed on this server, then every check. See [Recipes](#recipes). Deploy user only |

Allowed home folders: `/home/ploi`, `/home/forge`, `/home/eeploi`, the deploy user's, and `/srv/eeploi/<user>` of a site user.

Only the deploy user may call the helper, through sudo. `ploi`, `forge` and every other user are refused, for every subcommand. Since 1.0.2; before, `ploi` and `forge` could call the subcommands that take no site user.

## Site users

One Linux user per site, named like `shop_example`: a lowercase letter, then `a-z`, `0-9` or `_`, at most 32, with at least one `_` after the first letter. No standard user or group of the system or of a package has one. Never `root`, `eeploi`, the deploy user, `ploi`, `forge`, `ubuntu`, `www-data`, the nginx user and group, `postgres`, `mysql`, `redis`, `nobody` or `nogroup`. Never the name of a standard group that grants root or close to it, whether or not that group exists yet: `admin`, `wheel`, `sudo`, `adm`, `staff`, `shadow`, `disk`, `kmem`, `tty`, `utmp`, `crontab`, `docker`, `lxd`, `incus`, `libvirt`, `kvm`, `video`, `render`, `input`, `sgx`, `lpadmin`, `sambashare`, `operator`, `daemon`, `bin`, `sys`, `backup` and `syslog`. `useradd` makes a group of the user's name, and a package installed later keeps a group that is already there.

**The registry.** `/etc/eeploi/sites/<user>`, one file per site user, owned by root, mode `644`. It holds `DOMAIN=<domain>` and every file and place of the site, one `KEY=value` line each, kept current by the subcommands that write or remove them:

```
DOMAIN=shop.example
HOME=/srv/eeploi/shop_example
VHOST=/etc/nginx/sites-available/shop.example
POOL=/etc/php/8.4/fpm/pool.d/eeploi-shop_example.conf
CRON=/etc/cron.d/eeploi-shop_example
SUPERVISOR=/etc/supervisor/conf.d/eeploi-shop.example-horizon.conf
LOGS=/var/log/supervisor/eeploi/shop_example
REDIS_CONF=/etc/eeploi/redis/shop_example.conf
REDIS_UNIT=eeploi-redis@shop_example.service
REDIS_DROPIN=/etc/systemd/system/eeploi-redis@shop_example.service.d/memory.conf
REDIS_SOCKET=/srv/eeploi/shop_example/.redis/redis.sock
```

The file is read line by line, never run. Only `DOMAIN` is used for checks. A file that is not root-owned, is a link, is writable by others, or has another line, is refused.

**The check.** Every subcommand that takes a site user first checks:

1. the name is valid, has an `_` after the first letter, and is not reserved;
2. its registry file is trusted, and lists the domain when one is given;
3. the user exists with uid 1000 or higher and home `/srv/eeploi/<user>`;
4. it is in no group but its own (`id -G`). A site user later added to `sudo`, `adm`, `docker` or another group is refused.

**`site-user-create <user> <domain>`.** Only for the deploy user itself. The domain must not be listed for another site user. The domain check and the new registry file happen under the registry's lock.

- Listed and there: the home gets `750` and the ACL again, and the answer is `exists: site user <user> for <domain>, nothing changed`.
- Listed, but the user is missing: the user is made.
- Not listed: no user, group or `/srv/eeploi/<user>` of that name may exist (`exists … and is not an eeploi site user`). The helper writes the registry file, makes `/srv/eeploi` (root, `755`) when missing, then runs `useradd --home-dir /srv/eeploi/<user> --create-home --user-group --shell /usr/sbin/nologin <user>`. When `useradd` fails, the registry file goes again.
- Then `chmod 750` on the home and `setfacl -m u:<nginx user>:x` (the `acl` package is installed first when `setfacl` is missing). Root changes the home folder itself, never anything in it.

**`run-as <user>`.** Only for the deploy user itself, with exactly one argument and the script on stdin. Neither stdin nor the output (stdout, stderr) may be a terminal. It runs, in a new session without a controlling terminal:

```
setsid --wait runuser -u <user> -- env -i HOME=/srv/eeploi/<user> USER=<user> LOGNAME=<user> PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 /bin/bash -s
```

`--wait` keeps the script's exit code.

The system log gets `run-as <user>`, never the script.

## Redis per site

Every site can have a Redis of its own, running as the site user. It listens on no TCP port, only on a socket in the site's home. The unit and config stay root-owned, so the site can't change them.

| File | Owner | Holds |
|---|---|---|
| `/etc/systemd/system/eeploi-redis@.service` | root | One template for every site: `redis-server` with the site's config, as `User=%i` and `Group=%i`. Only Unix sockets (`RestrictAddressFamilies=AF_UNIX`), no swap (`MemorySwapMax=0`), only `.redis` writable (`ProtectSystem=strict`), and the kernel, cgroups, clock, devices and hostname out of reach (`Protect*`, `PrivateDevices`, `PrivateTmp`, `NoNewPrivileges`) |
| `/etc/systemd/system/eeploi-redis@<user>.service.d/memory.conf` | root | `MemoryMax`: the size plus 36 MB for Redis itself and its rewrite child |
| `/etc/eeploi/redis/<user>.conf` | root | `port 0`, `unixsocket /srv/eeploi/<user>/.redis/redis.sock` with `unixsocketperm 600`, `dir /srv/eeploi/<user>/.redis`, `appendonly yes`, `maxmemory <mb>mb`, `maxmemory-policy noeviction`, `enable-module-command no` and `enable-debug-command no` (both need Redis 7) |
| `/srv/eeploi/<user>/.redis` | the site user | The socket and the data, mode `700` |

- **`redis-create <user> [<mb>]`:** `<mb>` is a whole number from 32 to 1024, 128 by default (`maxmemory 128mb`, `MemoryMax=164M`). Writes the template (when missing or different), the config and the drop-in, then `systemctl daemon-reload`. The site user makes its own `.redis` folder. It starts nothing. Called again, it rewrites the config and the drop-in, for example with a new size; a running Redis then restarts, and when that fails, the old template, config and drop-in come back. The registry changes only after a good restart, or when Redis wasn't running.
- **`redis-start <user>`:** refused before `redis-create`, and when `redis-server` is not installed. The helper never installs Redis.
- **`redis-stop <user>`:** the data stays in the home, so it is there again after `redis-start`.

## Settings on the server

Two optional files, both owned by root and not writable by anyone else. The helper refuses to run when they are not.

| File | Does |
|---|---|
| `/etc/eeploi/helper.conf` | `DEPLOY_USER=<user>`, when the deploy user is not `eeploi`. Only that line and comments are allowed. The file is read, never run |
| `/etc/eeploi/new-server` | Marker written when eeploi created the server. Without it, `firewall-close-22` refuses. On a server you bring yourself, eeploi never touches the SSH port or the firewall |
| `/etc/eeploi/recipes.conf` | The values the recipes use, written at the first boot: `DEPLOY_USER=<user>` (the same as the helper's), `SSH_PORT=<port>` (`22`, or `10000` to `32767`) and `PHP=<version>` (`N.N`), each once, and comments. Read line by line, never run. Without it, `recipe-run` refuses |

The helper writes two folders there itself: `/etc/eeploi/sites` (the registry, see [Site users](#site-users)) and `/etc/eeploi/redis`. The same rules apply to them.

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
- **The Unix user (socket login):** must pass the [site user check](#site-users): socket login is only for a user the helper made, never a system user or one that runs more than one site (the deploy user, `eeploi`, `ploi`, `forge`).
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
VERSION=1.0.2
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

## Recipes

A server eeploi creates is built at its first boot by the steps of an [eeploi recipes](https://github.com/eeploi/recipes) release. `recipe-run` brings a later release to that server:

```bash
sudo eeploi-helper recipe-run 0.4.0 hetzner
```

1. Checks the version (`x.y.z`) and the provider (`a-z`, `0-9` and `-`), reads `/etc/eeploi/recipes.conf` (see [Settings on the server](#settings-on-the-server)) and this server's OS from `/etc/os-release` (`ID` and `VERSION_ID`, read line by line, never run), such as `ubuntu-26.04`.
2. Refuses a release older than the last one that ran well here. The same release may run again.
3. Downloads the release's manifest for that provider and OS, `recipes-<version>-<provider>-<os>.manifest`, and its `.minisig` from GitHub, and checks the signature with the recipes key built into the helper (`RECIPES_PUBKEY`, a key of its own, apart from the helper's). A bad signature stops it: nothing else is downloaded, nothing runs.
4. Reads the manifest line by line: `format 1`, the `release` asked for, the `target` `<provider> <os>` of this server, a `min-helper` no newer than this helper, then a `step` line per step in run order (its SHA-256, its marker `first-boot`, `always` or `window`, and its path) and a `file` line per other file. A path that is absolute, has `.` or `..` parts, or appears twice is refused.
5. Downloads the package `recipes-<version>.tar.gz` (4 MB at most, 8 MB unzipped, at most 200 files in the manifest). A package with a link or any other file that is not a plain file or folder is refused. Reads every file the manifest lists out of it, one by one, into a folder of its own; the package is never unpacked as it is. Each file must match its SHA-256, so a changed or a missing file is refused before anything runs. The files a run uses may hold no placeholder but `{user}`, `{port}`, `{php}`, `{version}` and `{name}`, and those never in bash's own braces (`${user}`).
6. Runs the `always` steps in order, each as `stack/start.sh`, `stack/values.sh` and the step under `set -euo pipefail`, with the values from `recipes.conf` and the OS filled in: a step that is new or changed since the last good run here, and an unchanged one whose check fails now. `first-boot` and `window` steps never run. A failed step stops the steps after it.
7. Runs every check of the release, each on its own after the values, under `set -euo pipefail`. Checks only read.
8. After every step went well, writes `/var/lib/eeploi/recipes/state` (root-owned): the release and the SHA-256 of each step.

Steps and checks run as root, from `/`, with a clean environment and no stdin. What they print goes to stderr. One `recipe-run` at a time. stdout has only these lines, and a line per step and per run goes to the system log:

```
recipe-run 0.4.0 hetzner ubuntu-26.04
step same stack/06-fail2ban.sh
step ran stack/07-updates.sh
step failed stack/09-logs.sh
step skipped <each step after a failed one>
check ok stack/07-updates.check.sh
check failed stack/09-logs.check.sh
result failed
```

Exit `0`: every step and check went well. `1`: a step or check failed, or the run stopped after its steps started (then there may be no `result` line). `64`: refused, nothing ran. A server built before the recipes wrote `recipes.conf`, or one eeploi took over, has no such file and is refused.

## Dry run

`EEPLOI_HELPER_DRY_RUN=1` checks every argument and prints what the helper would run or write. It changes nothing. sudo drops the variable, so it is for tests only.

```bash
EEPLOI_HELPER_DRY_RUN=1 SUDO_USER=eeploi bash eeploi-helper php-fpm-reload 8.4
```

In dry-run mode only, `EEPLOI_HELPER_ETC` and `EEPLOI_HELPER_NGINX_CONF` point to test copies of `/etc/eeploi` and `nginx.conf`, and `EEPLOI_HELPER_DB_STATE` to a file with what `db-create`'s checks would find (`key=count` lines). A dry run of `db-create` prints the SQL with `<password>` in place of the password. `EEPLOI_HELPER_VHOST` points to a vhost for `vhost-set-root`, which then prints the vhost it would write, and for the include and log check of `vhost-set-socket`. Their includes count from the folder of `EEPLOI_HELPER_NGINX_CONF`, and `EEPLOI_HELPER_NGINX_LOGS` points to a test copy of `/var/log/nginx`.

`EEPLOI_HELPER_SYSTEM` points to a file with what the site-user checks would find on the server: `passwd <getent passwd line>`, `group <getent group line>`, `id <user>:<id -G output>`, `path <path that exists>` and `active <running unit>`. Without it, none of them exist. A dry run prints every file it would write, the registry included.

For `recipe-run`: `EEPLOI_HELPER_OS_RELEASE` points to a test `os-release`, `EEPLOI_HELPER_RECIPES_STATE` to a test state folder, `EEPLOI_HELPER_RECIPES_DOWNLOAD` to a folder with the release's files (copied in place of the download, then checked as usual), `EEPLOI_HELPER_RECIPES_RESULTS` to a file of `fail <path>` lines for the steps and checks that fail (and a `locked` line when another run holds the lock), and `EEPLOI_HELPER_MINISIGN` to a `minisign` outside `PATH`. A dry run never runs a step or check: it prints each script.

## Tests

```bash
bash tests/run.sh
```

Plain bash and `minisign`: the `recipe-run` cases sign test releases with a key pair made for the run. Runs `bash -n`, `shellcheck` when installed, and the dry-run cases. CI runs it on every push.

## Security model

- **Fixed actions.** Each subcommand does one thing. There is no way to pass a command.
- **Checked input.** Domains, paths, versions, sockets and configs are checked against strict patterns. Paths must stay inside the allowed home folders, also after resolving links.
- **One user per site.** Each site runs as its own Linux user, listed in a root-owned registry. The helper acts as a site user only after the site user check, and root writes nothing inside a site's home. The one exception, `releases-own`, only hands the site's releases back to the site user.
- **Called through sudo.** The helper refuses to run unless `SUDO_USER` is an allowed user.
- **Fixed environment.** The first line is `#!/bin/bash`, never a `bash` found on `PATH`. `PATH`, `TMPDIR`, `HOME` (`/root`), the locale (`LC_ALL=C`) and the umask are set by the helper, not taken from the caller. `curl` reads no curlrc.
- **Signed releases.** Every release is signed with minisign. The helper only installs a release signed with the key built into it.
- **Signed recipes.** `recipe-run` runs only steps from a recipes release signed with the recipes key built into the helper, each file checked against the signed manifest. The values come from a root-owned file on the server, never from the caller.
- **The signing key is offline.** It never touches GitHub or eeploi.com. A hacked eeploi.com or GitHub account still cannot ship a helper your server accepts.

Found a problem? See [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
