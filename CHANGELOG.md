# Changelog

All notable changes to eeploi-helper. Versions follow [semver](https://semver.org): a removed or changed subcommand is a major release, a new subcommand a minor one. While eeploi is in development, every change ships as a patch release (since 2026-11-13).

## 1.0.4 (2026-11-17)

Closes two gaps in 1.0.3's checks, checks the files nginx reads as root, and lets take-overs through that 1.0.3 refused.

- Changed: `vhost-set-root` and `vhost-set-socket` split a vhost's words on a carriage return too, as nginx does.
- Changed: `vhost-set-root` and `vhost-set-socket` also check every `ssl_certificate`, `ssl_certificate_key`, `ssl_dhparam`, `ssl_password_file` and `auth_basic_user_file`, with the rule for includes: in `/etc/nginx`, and the file and every folder up to there root-owned and not writable by group or others. A certificate elsewhere, such as certbot's in `/etc/letsencrypt`, is refused: eeploi uses its own, in `/etc/nginx/ssl`.
- Changed: an include, log or file path in quotes (`include "snippets/fastcgi-php.conf";`) is read without them and checked like any other. A word with more than one pair of quotes is still refused.
- Changed: `releases-own` hands back only folders and files with one link, in one walk over the releases, from inside each folder.

## 1.0.3 (2026-11-17)

Root runs and reads as code only files that root alone can change.

- Changed: the first line is `#!/bin/bash`, so sudo never runs a `bash` found on `PATH`.
- Changed: `vhost-set-root` and `vhost-set-socket` check what the vhost includes and logs to. Every `include`, also in included files, must be in `/etc/nginx`, every `access_log` and `error_log` in `/var/log/nginx`. Each included file and every folder up to there must be root-owned and not writable by group or others, and a log may not be a link. A line nginx could read differently than the helper (a quote with a `#`, an open quote, a `#` inside a word) is refused. Otherwise the vhost is refused and stays as it was.
- New subcommand `releases-own <user>`: gives what root or the deploy user owns in the site's `releases` folder back to the site user, with `chown -R -P -h --from=<owner>` from inside the site's folder, only with `fs.protected_hardlinks` on. eeploi.com calls it instead of asking for a `chown` as root.

## 1.0.2 (2026-11-15)

Every site runs as its own Linux user, a site user, with its home in `/srv/eeploi/<user>`. A patch release while eeploi is in development, though subcommands change shape.

- New: a root-owned registry, `/etc/eeploi/sites/<user>`, with the site's domain and every file and place of it. Read line by line, never run, refused unless root-owned and not writable by others. Every subcommand that takes a site user checks it first: a valid, unreserved name with an `_` after the first letter (like `shop_example`), listed in the registry, uid 1000 or higher, home `/srv/eeploi/<user>`, and no group but its own. The names of standard groups that grant root or close to it (`docker`, `lxd`, `libvirt`, `admin`, `sudo` and others) are refused, also before such a group exists.
- New subcommand `site-user-create <user> <domain>`: the registry file, the user and its group, and the home (`750`, with an ACL so the nginx user may pass through). A user, group or home of that name that isn't listed is refused. Called again, it changes nothing. The domain check and the new registry file happen under the registry's lock.
- New subcommand `run-as <user>`: runs the script from stdin as the site user, with `runuser` and a clean environment, in a new session (`setsid --wait`). Stdin, stdout and stderr may not be a terminal. Nothing goes on the command line; the system log gets the user, never the script.
- New subcommands `redis-create <user> [<mb>]`, `redis-start <user>` and `redis-stop <user>`: a Redis per site, running as the site user, on a socket in its home and no TCP port. The unit, its memory drop-in and the config are root-owned. The unit allows only Unix sockets and no swap, and keeps the kernel, cgroups and devices out of reach. The config turns off the `MODULE` and `DEBUG` commands. The size is 32 to 1024 MB, 128 by default. `redis-create` starts nothing; `redis-start` needs `redis-server` installed. The helper never installs Redis. When a running Redis fails to restart, `redis-create` puts back the template, the config and the drop-in, and the registry changes only after a good restart.
- Only the deploy user may call the helper. `ploi` and `forge` are refused for every subcommand; in 1.0.1 they could call the ones that take no site user, such as `vhost-enable`, `ssl-write` or `crontab-remove-lines`. eeploi always calls as the deploy user, also during a takeover.
- Changed: `php-pool-write <version> <user>` writes one pool per site, `pool.d/eeploi-<user>.conf`, running as the site user, with at most 5 workers and a 60 second request limit, and a socket only the nginx user may open (`listen.mode = 0600`, no group access), plus `conf.d/90-eeploi.ini` with `opcache.validate_permission = 1`. The shared `[eeploi]` pool is no longer written. A new PHP version for a site removes the site's pool of the old version, once the new one passes `php-fpm -t`, and puts both back when the old version's test fails.
- Changed: `vhost-write <domain> <user> <php-version>` builds the root `/srv/eeploi/<user>/<domain>/current/public` and the socket of the site's pool itself. nginx follows a link in the site only when the link and its target have the same owner (`disable_symlinks if_not_owner`).
- Changed: `supervisor-write <program> <user> <directory> <processes>` runs the program as the site user, only for its own domain and a folder under its site. After `eeploi-<domain>-` the name has no dot, and a name that also fits another listed domain is refused. The log goes to `/var/log/supervisor/eeploi/<user>/`, readable by that site only. A `%` in the command is refused, since supervisord expands it. The name check and the write happen under the registry's lock. `supervisor-remove-site` removes only the programs the site's registry lists, and their `.paused` copies. `supervisor-pause` and `supervisor-resume` of an `eeploi-*` program run only for the deploy user.
- Changed: `cron-write <user>` and `cron-remove <user>` use `/etc/cron.d/eeploi-<user>`, a name without dots. The line runs as the site user, on its own site's `artisan`.
- Changed: `env-install` and `storage-copy` copy into the home of the site user `<owner>`, who writes the copy. Sources stay limited to `/home/ploi` and `/home/forge`, and `ploi` or `forge` reads them; root opens neither path.
- Changed: `vhost-set-root` and `vhost-set-socket` also accept a site user's home and socket, only for that user's own domain. A root moved into a site home gets eeploi's `disable_symlinks` line next to it; that root must sit at the top level of a server block on port 443 exactly, and a line that combines a quote with `{`, `}` or `#` is refused; `vhost-set-root` now changes exactly one root line and runs `nginx -t`. The new socket of `vhost-set-socket` is always the site's own pool; the old one may also be the default socket, 1.0.1's `php<version>-fpm-eeploi.sock` or a panel's pool per user.
- Changed: `vhost-remove` runs every check before it removes anything.
- Changed: `vhost-remove`, `supervisor-remove` and `supervisor-remove-site` work on a server without site users yet: the registry's folder is made before its lock.
- Changed: `db-create` with socket login needs a site user; the separate check of the Linux user (`id -u`) is gone, and so is the `uid=` line of the dry-run database state.
- Removed: `acl-nginx`. `site-user-create` sets the ACL per site.

## 1.0.1 (2026-11-13)

- `db-create` with password login on MySQL and MariaDB makes the user on `127.0.0.1` too, with the same password and grant, so Laravel's default `DB_HOST=127.0.0.1` works without a name lookup. Only for a new user: a user that exists, such as one from 1.0.0, stays on `localhost` only, since the password on stdin could be anyone's. Socket login and Postgres are unchanged. Refused: a user on `127.0.0.1` for socket login, and one on `127.0.0.1` without one on `localhost`.

## 1.0.0, files replaced (2026-11-10)

- New subcommand `db-create <engine> <name> <user> <socket|password>` (a minor release): creates a MySQL, MariaDB or Postgres database and its user for a new site. The user gets that one database and no global rights. Two ways in, named by the required fourth argument:
  - `socket`: socket login as the Unix user of the same name, with no password at all (Postgres peer auth, MariaDB `unix_socket`, MySQL `auth_socket`). Stdin is never read. The Unix user must exist and be a site's own user. On MySQL the `auth_socket` plugin is installed when it is not active.
  - `password`: password login, with the password on stdin. A missing or invalid password, or a terminal, is refused; it never falls back to socket login. The password is never printed, logged or on a command line.
  - Names are `a-z`, `0-9` and `_` only, so a site user like `shop_example` needs no quoting.
  - Both already there with the same way in is a no-op. A database or user someone else has, and a user with the other way in, are refused. The system log gets the engine, name, user and login, never the password.
- Fixes from the second helper audit (2026-11-10):
  - `env-install` only copies a file named `.env`, and `storage-copy` only a folder named `storage`: the source must end in `/.env` or `/storage`, also after resolving links. Anything else is refused.
  - `self-update` only installs a strictly newer version. The same version is now refused too.
  - `ssl-csr` makes the private key with mode `600` from the start.
  - The helper sets `HOME=/root` and `LC_ALL=C` itself, and `self-update` runs `curl -q`, so no curlrc is read.
- Every call except `version` goes to the system log (`logger -t eeploi-helper`): the caller, the subcommand and its arguments, never stdin. A dry run prints the line on stderr. Not yet: the timeline event id.

## 1.0.0 (2026-11-08)

First public release. The helper moves out of eeploi.com into this repo.

Subcommands:

- `version`
- `nginx-test`, `nginx-reload`
- `php-fpm-reload`, `php-pool-write` (new)
- `vhost-write`, `vhost-backup`, `vhost-restore`, `vhost-enable`, `vhost-disable`, `vhost-remove`
- `vhost-set-root`, `vhost-set-cert`, `vhost-set-socket` (new)
- `ssl-csr`, `ssl-write`, `ssl-remove`
- `supervisor-write`, `supervisor-remove`, `supervisor-remove-site`, `supervisor-pause`, `supervisor-resume`, `supervisor-update`
- `cron-write`, `cron-remove`, `crontab-remove-lines`, `crontab-restore`
- `env-install`, `storage-copy`
- `firewall-close-22`
- `acl-nginx` (new), installs the `acl` package when `setfacl` is missing
- `self-update` (new)

Changes from the helper built into eeploi.com:

- `version` prints the release version (`1.0.0`) instead of `1`.
- One file for every server. The deploy user comes from `/etc/eeploi/helper.conf`, not from a build step.
- `firewall-close-22` is always in the file, but only runs when `/etc/eeploi/new-server` exists.

Security fixes before release (server-access audit, 2026-11-09):

- `vhost-write <domain> <socket>` builds the vhost itself; it no longer takes a config on stdin. Logs go to `/var/log/nginx`.
- `vhost-backup` and `vhost-restore` replace `vhost-read`, `ssl-read` and `ssl-include-write` for take-overs. The backup stays root-only.
- `supervisor-write <program> <directory> <processes>` builds the config itself from a one-line command. Logs go to `/var/log/supervisor`.
- `env-install` and `storage-copy` only read from `/home/ploi` or `/home/forge`, and the caller writes the copy, never root.
- `crontab-remove-lines <domain>` only removes `ploi` or `forge` jobs in their home and keeps them; `crontab-restore` adds just those back. `crontab-backup` is gone.
- `ssl-write` only accepts one PEM certificate.
- `self-update` refuses an older version.
