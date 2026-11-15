# Changelog

All notable changes to eeploi-helper. Versions follow [semver](https://semver.org): a removed or changed subcommand is a major release, a new subcommand a minor one.

## 1.0.2 (2026-11-15)

Every site runs as its own Linux user, a site user, with its home in `/srv/eeploi/<user>`. A patch release while eeploi is in development, though subcommands change shape.

- New: a root-owned registry, `/etc/eeploi/sites/<user>`, with the site's domain and every file and place of it. Read line by line, never run, refused unless root-owned and not writable by others. Every subcommand that takes a site user checks it first: a valid, unreserved name, listed in the registry, uid 1000 or higher, home `/srv/eeploi/<user>`, and no group but its own. The names of standard groups that grant root or close to it (`docker`, `lxd`, `libvirt`, `admin`, `sudo` and others) are refused, also before such a group exists.
- New subcommand `site-user-create <user> <domain>`: the registry file, the user and its group, and the home (`750`, with an ACL so the nginx user may pass through). A user, group or home of that name that isn't listed is refused. Called again, it changes nothing. The domain check and the new registry file happen under the registry's lock.
- New subcommand `run-as <user>`: runs the script from stdin as the site user, with `runuser` and a clean environment, in a new session (`setsid --wait`). Stdin, stdout and stderr may not be a terminal. Nothing goes on the command line; the system log gets the user, never the script.
- New subcommands `redis-create <user> [<mb>]`, `redis-start <user>` and `redis-stop <user>`: a Redis per site, running as the site user, on a socket in its home and no TCP port. The unit, its memory drop-in and the config are root-owned. The unit allows only Unix sockets and no swap, and keeps the kernel, cgroups and devices out of reach. The config turns off the `MODULE` and `DEBUG` commands. The size is 32 to 1024 MB, 128 by default. `redis-create` starts nothing; `redis-start` needs `redis-server` installed. The helper never installs Redis.
- Every subcommand that takes a site user, writes a site's registry or removes its Supervisor programs runs only for the deploy user itself, not for `ploi` or `forge`.
- Changed: `php-pool-write <version> <user>` writes one pool per site, `pool.d/eeploi-<user>.conf`, running as the site user, with at most 5 workers and a 60 second request limit, plus `conf.d/90-eeploi.ini` with `opcache.validate_permission = 1`. The shared `[eeploi]` pool is no longer written.
- Changed: `vhost-write <domain> <user> <php-version>` builds the root `/srv/eeploi/<user>/<domain>/current/public` and the socket of the site's pool itself. nginx follows a link in the site only when the link and its target have the same owner (`disable_symlinks if_not_owner`).
- Changed: `supervisor-write <program> <user> <directory> <processes>` runs the program as the site user, only for its own domain and a folder under its site. After `eeploi-<domain>-` the name has no dot, and a name that also fits another listed domain is refused. The log goes to `/var/log/supervisor/eeploi/<user>/`, readable by that site only. `supervisor-remove-site` removes only the programs the site's registry lists.
- Changed: `cron-write <user>` and `cron-remove <user>` use `/etc/cron.d/eeploi-<user>`, a name without dots. The line runs as the site user, on its own site's `artisan`.
- Changed: `env-install` and `storage-copy` copy into the home of the site user `<owner>`, who writes the copy. Sources stay limited to `/home/ploi` and `/home/forge`, and `ploi` or `forge` reads them; root opens neither path.
- Changed: `vhost-set-root` and `vhost-set-socket` also accept a site user's home and socket, only for that user's own domain. `db-create` with socket login needs a site user.
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
